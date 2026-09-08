import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/ui/request_state.dart';
import '../auth/session_controller.dart';
import '../paywall/paywall_sheet.dart';
import 'edit_controller.dart';
import 'pdf_repository.dart';
import 'pdf_tool.dart';
import '../../core/files/picked_file.dart';

/// One screen per tool: pick files, fill in the tool's fields, run.
class ToolPage extends StatelessWidget {
  const ToolPage({super.key, required this.tool});

  final PdfTool tool;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => EditController(
        tool: tool,
        repository: context.read<PdfRepository>(),
        session: context.read<SessionController>(),
      ),
      child: _ToolView(tool: tool),
    );
  }
}

class _ToolView extends StatefulWidget {
  const _ToolView({required this.tool});

  final PdfTool tool;

  @override
  State<_ToolView> createState() => _ToolViewState();
}

class _ToolViewState extends State<_ToolView> {
  final _formKey = GlobalKey<FormState>();

  final _pageRanges = TextEditingController(text: '1');
  final _text = TextEditingController();
  final _page = TextEditingController(text: '1');
  final _x = TextEditingController(text: '72');
  final _y = TextEditingController(text: '72');

  bool _recompressImages = false;
  double _imageQuality = 70;
  int _degrees = 90;

  @override
  void dispose() {
    _pageRanges.dispose();
    _text.dispose();
    _page.dispose();
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final controller = context.read<EditController>();
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    await controller.run(
      EditOptions(
        imageQuality: _recompressImages ? _imageQuality.round() : null,
        pageRanges: _pageRanges.text.trim(),
        text: _text.text,
        page: int.tryParse(_page.text.trim()),
        x: double.tryParse(_x.text.trim()),
        y: double.tryParse(_y.text.trim()),
        degrees: _degrees,
      ),
    );

    if (!mounted) return;
    // The paywall is the response to a quota failure, not a red banner.
    if (controller.state case QuotaExceeded(:final error)) {
      await showPaywall(context, resetsAt: error.resetsAt);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditController>();
    final tool = widget.tool;

    return Scaffold(
      appBar: AppBar(title: Text(tool.label)),
      body: AbsorbPointer(
        absorbing: controller.state.isLoading,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(tool.description, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),

              _FilePicker(controller: controller),
              const SizedBox(height: 16),

              ..._optionFields(tool),

              const SizedBox(height: 8),
              _RunButton(controller: controller, onRun: _run),

              if (controller.state.isLoading) ...[
                const SizedBox(height: 16),
                _UploadProgress(progress: controller.uploadProgress),
              ],

              const SizedBox(height: 16),
              _ResultSection(state: controller.state, onReset: controller.reset),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _optionFields(PdfTool tool) {
    switch (tool) {
      case PdfTool.merge:
        return const [];

      case PdfTool.compress:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _recompressImages,
            onChanged: (value) => setState(() => _recompressImages = value),
            title: const Text('Recompress images'),
            subtitle: const Text(
              'Much smaller for scans, but images lose some detail.',
            ),
          ),
          if (_recompressImages)
            Slider(
              value: _imageQuality,
              min: 20,
              max: 95,
              divisions: 15,
              label: 'Quality ${_imageQuality.round()}',
              onChanged: (value) => setState(() => _imageQuality = value),
            ),
        ];

      case PdfTool.split:
        return [
          TextFormField(
            controller: _pageRanges,
            decoration: const InputDecoration(
              labelText: 'Pages',
              helperText: 'e.g. 1-3,7 — several ranges come back as a ZIP.',
              prefixIcon: Icon(Icons.filter_1),
            ),
            validator: (value) => (value?.trim().isEmpty ?? true)
                ? 'Enter at least one page or range.'
                : null,
          ),
        ];

      case PdfTool.rotate:
        return [
          TextFormField(
            controller: _pageRanges,
            decoration: const InputDecoration(labelText: 'Pages', helperText: 'e.g. 1-3,7'),
            validator: (value) => value?.trim().isEmpty ?? true ? 'Enter pages.' : null,
          ),
          DropdownButtonFormField<int>(
            initialValue: _degrees,
            decoration: const InputDecoration(labelText: 'Rotation'),
            items: const [90, 180, 270].map((value) => DropdownMenuItem(value: value, child: Text('$value degrees'))).toList(),
            onChanged: (value) => setState(() => _degrees = value ?? 90),
          ),
        ];

      case PdfTool.deletePages:
        return [
          TextFormField(
            controller: _pageRanges,
            decoration: const InputDecoration(labelText: 'Pages to delete', helperText: 'e.g. 2,4-5'),
            validator: (value) => value?.trim().isEmpty ?? true ? 'Enter pages.' : null,
          ),
        ];

      case PdfTool.reorderPages:
        return [
          TextFormField(
            controller: _pageRanges,
            decoration: const InputDecoration(labelText: 'New order', helperText: 'e.g. 3,1,2'),
            validator: (value) => value?.trim().isEmpty ?? true ? 'Enter page order.' : null,
          ),
        ];

      case PdfTool.addText:
        return [
          TextFormField(
            controller: _text,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: 'Text',
              prefixIcon: Icon(Icons.short_text),
            ),
            validator: (value) =>
                (value?.isEmpty ?? true) ? 'Enter the text to add.' : null,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  controller: _page,
                  label: 'Page',
                  validator: (value) {
                    final page = int.tryParse(value ?? '');
                    return (page == null || page < 1) ? 'Page 1 or higher.' : null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _NumberField(controller: _x, label: 'X (pt)')),
              const SizedBox(width: 12),
              Expanded(child: _NumberField(controller: _y, label: 'Y (pt)')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Position is measured in points from the top-left corner '
            '(72 pt = 1 inch).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];
    }
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
      decoration: InputDecoration(labelText: label),
      validator: validator ??
          (value) => double.tryParse(value ?? '') == null ? 'Number?' : null,
    );
  }
}

class _FilePicker extends StatelessWidget {
  const _FilePicker({required this.controller});

  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final files = controller.files;
    final tool = controller.tool;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: controller.pickFiles,
          icon: const Icon(Icons.attach_file),
          label: Text(
            files.isEmpty
                ? (tool.allowsMultiple ? 'Choose PDFs' : 'Choose a PDF')
                : (tool.allowsMultiple ? 'Add another PDF' : 'Choose a different PDF'),
          ),
        ),
        if (files.isNotEmpty) ...[
          const SizedBox(height: 8),
          if (tool.allowsMultiple)
            Text(
              'Drag to set the order they are joined in.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          // Merge cares about order, so its list is reorderable; the others
          // hold exactly one file and do not need the drag affordance.
          if (tool.allowsMultiple)
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: files.length,
              onReorder: controller.reorderFile,
              itemBuilder: (context, index) => _FileTile(
                // ObjectKey, not a path: a browser pick has no path, and a
                // key containing the index would change as items reorder.
                key: ObjectKey(files[index]),
                file: files[index],
                index: index,
                showHandle: true,
                onRemove: () => controller.removeFile(index),
              ),
            )
          else
            _FileTile(
              key: ObjectKey(files.first),
              file: files.first,
              index: 0,
              showHandle: false,
              onRemove: () => controller.removeFile(0),
            ),
        ],
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.file,
    required this.index,
    required this.showHandle,
    required this.onRemove,
  });

  final PickedFile file;
  final int index;
  final bool showHandle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.picture_as_pdf_outlined),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(file.readableSize),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
          ),
          if (showHandle)
            ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
        ],
      ),
    );
  }
}

class _RunButton extends StatelessWidget {
  const _RunButton({required this.controller, required this.onRun});

  final EditController controller;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final needed = controller.tool.minimumFiles;
    final missing = needed - controller.files.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: controller.canRun ? onRun : null,
          icon: controller.state.isLoading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Icon(controller.tool.icon),
          label: Text(
            controller.state.isLoading ? 'Working…' : controller.tool.label,
          ),
        ),
        if (missing > 0) ...[
          const SizedBox(height: 8),
          Text(
            missing == needed
                ? 'Choose ${needed == 1 ? 'a file' : '$needed files'} to continue.'
                : 'Choose $missing more file${missing == 1 ? '' : 's'}.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _UploadProgress extends StatelessWidget {
  const _UploadProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    // Once the bytes are sent the server is still working, so switch to an
    // indeterminate bar rather than parking at 100% with nothing happening.
    final uploading = progress > 0 && progress < 1;

    return Column(
      children: [
        LinearProgressIndicator(value: uploading ? progress : null),
        const SizedBox(height: 8),
        Text(
          uploading
              ? 'Uploading… ${(progress * 100).round()}%'
              : 'Processing on the server…',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Renders whichever of the four states the request is in.
class _ResultSection extends StatelessWidget {
  const _ResultSection({required this.state, required this.onReset});

  final RequestState<EditedFile> state;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return switch (state) {
      Idle() || Loading() => const SizedBox.shrink(),
      Success(:final value) => _SuccessCard(result: value, onReset: onReset),
      // The sheet is already shown by the page; this is the trace it leaves.
      QuotaExceeded(:final error) => _Banner(
          icon: Icons.workspace_premium_outlined,
          message: error.message,
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
          action: TextButton(
            onPressed: () => showPaywall(context, resetsAt: error.resetsAt),
            child: const Text('See Premium'),
          ),
        ),
      Failure(:final error) => _Banner(
          icon: Icons.error_outline,
          message: error.message,
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
        ),
    };
  }
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({required this.result, required this.onReset});

  final EditedFile result;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Saved',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              result.name,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              result.file.location,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
            ),
            if (result.quotaRemaining != null) ...[
              const SizedBox(height: 8),
              Text(
                '${result.quotaRemaining} edit'
                '${result.quotaRemaining == 1 ? '' : 's'} left this week.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                // A browser download has no path to copy, so the button only
                // appears where there is a real one.
                if (result.file.path case final path?)
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: path));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Path copied.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy path'),
                  ),
                const Spacer(),
                TextButton(onPressed: onReset, child: const Text('Start over')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.background,
    required this.foreground,
    this.action,
  });

  final IconData icon;
  final String message;
  final Color background;
  final Color foreground;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: foreground),
              const SizedBox(width: 10),
              Expanded(child: Text(message, style: TextStyle(color: foreground))),
            ],
          ),
          if (action != null)
            Align(alignment: Alignment.centerRight, child: action!),
        ],
      ),
    );
  }
}
