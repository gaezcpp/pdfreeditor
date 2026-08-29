import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/request_state.dart';
import '../auth/session_controller.dart';
import '../paywall/paywall_sheet.dart';
import 'editor_controller.dart';
import 'editor_models.dart';
import 'editor_repository.dart';

/// The WYSIWYG editor: the rendered page, with every editable object drawn as a
/// tappable box on top of it.
class EditorPageScreen extends StatelessWidget {
  const EditorPageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => EditorController(
        repository: context.read<EditorRepository>(),
        session: context.read<SessionController>(),
      ),
      child: const _EditorView(),
    );
  }
}

class _EditorView extends StatelessWidget {
  const _EditorView();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();
    final document = controller.document;

    return PopScope(
      canPop: document == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _confirmLeave(context, controller);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(document?.filename ?? 'Edit a document'),
          actions: document == null
              ? null
              : [
                  IconButton(
                    tooltip: 'Undo',
                    onPressed: document.hasEdits && !controller.isBusy
                        ? controller.undo
                        : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    tooltip: 'Revert everything',
                    onPressed: document.hasEdits && !controller.isBusy
                        ? () => _confirmRevert(context, controller)
                        : null,
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
        ),
        body: _body(context, controller),
        bottomNavigationBar:
            document == null ? null : _SaveBar(controller: controller),
      ),
    );
  }

  Widget _body(BuildContext context, EditorController controller) {
    return switch (controller.state) {
      Loading() => const _Centered(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Reading the document…'),
            ],
          ),
        ),
      QuotaExceeded(:final error) => _Centered(
          child: _Message(
            icon: Icons.workspace_premium_outlined,
            title: 'No edits left this week',
            detail: error.message,
            action: FilledButton(
              onPressed: () => showPaywall(context, resetsAt: error.resetsAt),
              child: const Text('See Premium'),
            ),
          ),
        ),
      Failure(:final error) => _Centered(
          child: _Message(
            icon: Icons.error_outline,
            title: 'That did not work',
            detail: error.message,
            action: FilledButton(
              onPressed: controller.openDocument,
              child: const Text('Try another file'),
            ),
          ),
        ),
      _ when controller.document == null => _Centered(
          child: _Message(
            icon: Icons.edit_document,
            title: 'Edit a PDF',
            detail: 'Open a document to change its text, or replace and remove '
                'its images. Nothing is charged until you save.',
            action: FilledButton.icon(
              onPressed: controller.openDocument,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose a PDF'),
            ),
          ),
        ),
      _ => _Canvas(controller: controller),
    };
  }

  Future<void> _confirmRevert(
    BuildContext context,
    EditorController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revert every change?'),
        content: const Text('The document goes back to how it was opened.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revert'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await controller.revertAll();
  }

  Future<void> _confirmLeave(
    BuildContext context,
    EditorController controller,
  ) async {
    final navigator = Navigator.of(context);
    final document = controller.document;

    if (document != null && document.hasEdits) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard your edits?'),
          content: const Text('They have not been saved to a file yet.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (!(leave ?? false)) return;
    }

    await controller.discard();
    navigator.pop();
  }
}

/// The rendered page with the object overlay on top.
class _Canvas extends StatelessWidget {
  const _Canvas({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final document = controller.document!;
    final page = controller.page!;
    final image = controller.pageImage;

    return Column(
      children: [
        if (controller.isBusy) const LinearProgressIndicator(),
        Expanded(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Fit the page to whichever axis runs out first, then map
                    // PDF points to pixels with that single scale. PyMuPDF's
                    // rects already use a top-left origin, so no axis flip.
                    final scale = _fitScale(constraints, page);
                    final size = Size(page.width * scale, page.height * scale);

                    return SizedBox(
                      width: size.width,
                      height: size.height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: image == null
                                ? const ColoredBox(
                                    color: Color(0xFFEEEEEE),
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  )
                                : Image.memory(
                                    image,
                                    key: ValueKey(
                                      '${document.id}-${page.number}-'
                                      '${document.revision}',
                                    ),
                                    fit: BoxFit.fill,
                                    gaplessPlayback: true,
                                  ),
                          ),
                          // Placing needs a point on the page, so the tap
                          // layer sits under the objects: it only catches taps
                          // that miss everything already there.
                          if (controller.placement != PlacementMode.none)
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) => _placeAt(
                                  context,
                                  controller,
                                  details.localPosition / scale,
                                ),
                              ),
                            ),
                          for (final span in page.spans)
                            _ObjectBox(
                              key: ValueKey('span-${span.index}'),
                              rect: span.bbox,
                              scale: scale,
                              selected: controller.selectedSpan?.index == span.index,
                              icon: Icons.text_fields,
                              isAdded: span.added,
                              onTap: () => _editSpan(context, controller, span),
                              onMove: (dx, dy) => controller.moveSpan(span, dx, dy),
                            ),
                          for (final image in page.images)
                            _ObjectBox(
                              key: ValueKey('image-${image.index}'),
                              rect: image.bbox,
                              scale: scale,
                              selected:
                                  controller.selectedImage?.index == image.index,
                              icon: Icons.image_outlined,
                              isImage: true,
                              isAdded: image.added,
                              onTap: () => _editImage(context, controller, image),
                              onMove: (dx, dy) => controller.moveImage(image, dx, dy),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (document.pageCount > 1)
          _PageBar(controller: controller, document: document),
        _Toolbar(controller: controller),
        _Hint(page: page, placement: controller.placement),
      ],
    );
  }

  double _fitScale(BoxConstraints constraints, EditorPage page) {
    final byWidth = constraints.maxWidth / page.width;
    if (!constraints.hasBoundedHeight) return byWidth;
    return byWidth < constraints.maxHeight / page.height
        ? byWidth
        : constraints.maxHeight / page.height;
  }

  Future<void> _editSpan(
    BuildContext context,
    EditorController controller,
    EditorSpan span,
  ) async {
    controller.select(span);
    final result = await showModalBottomSheet<_TextResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TextSheet(span: span),
    );
    if (result == null) return;

    if (result.delete) {
      await controller.deleteSpan(span);
      return;
    }
    if (result.text != span.text) {
      await controller.replaceText(span, result.text);
    }
    if ((result.size - span.size).abs() > 0.5) {
      await controller.setSpanStyle(span, size: result.size);
    }
  }

  Future<void> _placeAt(
    BuildContext context,
    EditorController controller,
    Offset point,
  ) async {
    switch (controller.placement) {
      case PlacementMode.text:
        final result = await showModalBottomSheet<_TextResult>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => const _TextSheet(span: null),
        );
        controller.cancelPlacing();
        if (result == null || result.text.trim().isEmpty) return;
        await controller.addTextAt(
          // The tap marks the baseline's left end, which is how PDF text is
          // positioned; without the nudge the text sits above the finger.
          x: point.dx,
          y: point.dy + result.size,
          text: result.text,
          size: result.size,
        );
      case PlacementMode.image:
        controller.cancelPlacing();
        await controller.addImageAt(x: point.dx, y: point.dy);
      case PlacementMode.none:
        break;
    }
  }

  Future<void> _editImage(
    BuildContext context,
    EditorController controller,
    EditorImage image,
  ) async {
    controller.select(image);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ImageSheet(image: image),
    );

    switch (action) {
      case 'replace':
        await controller.replaceImage(image);
      case 'delete':
        await controller.deleteImage(image);
      case 'bigger':
        await controller.scaleImage(image, 1.25);
      case 'smaller':
        await controller.scaleImage(image, 0.8);
    }
  }
}

/// A tappable, draggable outline over one object on the page.
///
/// The drag is tracked locally and committed once, on release. Sending an
/// operation per pointer movement would mean a server rebuild per frame, and
/// an undo stack with a hundred entries for one gesture.
class _ObjectBox extends StatefulWidget {
  const _ObjectBox({
    super.key,
    required this.rect,
    required this.scale,
    required this.selected,
    required this.icon,
    required this.onTap,
    required this.onMove,
    this.isImage = false,
    this.isAdded = false,
  });

  final Rect rect;
  final double scale;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  /// Called once on release, with the total distance in PDF points.
  final void Function(double dx, double dy) onMove;
  final bool isImage;
  final bool isAdded;

  @override
  State<_ObjectBox> createState() => _ObjectBoxState();
}

class _ObjectBoxState extends State<_ObjectBox> {
  Offset _drag = Offset.zero;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = widget.isImage ? scheme.tertiary : scheme.primary;
    final active = widget.selected || _dragging;

    return Positioned(
      left: widget.rect.left * widget.scale + _drag.dx,
      top: widget.rect.top * widget.scale + _drag.dy,
      width: widget.rect.width * widget.scale,
      height: widget.rect.height * widget.scale,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanStart: (_) => setState(() {
          _dragging = true;
          _drag = Offset.zero;
        }),
        onPanUpdate: (details) => setState(() => _drag += details.delta),
        onPanEnd: (_) {
          final moved = _drag;
          setState(() {
            _dragging = false;
            _drag = Offset.zero;
          });
          // Ignore the jitter of a tap that wandered a pixel or two.
          if (moved.distance < 2) return;
          // Screen pixels back to PDF points.
          widget.onMove(moved.dx / widget.scale, moved.dy / widget.scale);
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: active ? colour : colour.withValues(alpha: 0.45),
              width: active ? 2 : 1,
              style: widget.isAdded ? BorderStyle.solid : BorderStyle.solid,
            ),
            color: colour.withValues(alpha: active ? 0.18 : 0.06),
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.topRight,
          child: active
              ? Icon(widget.icon, size: 14, color: colour)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _TextResult {
  const _TextResult({
    required this.text,
    required this.size,
    this.delete = false,
  });

  final String text;
  final double size;
  final bool delete;
}

/// Edits an existing run, or composes a new one when [span] is null.
class _TextSheet extends StatefulWidget {
  const _TextSheet({required this.span});

  final EditorSpan? span;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.span?.text ?? '');
  late double _size = widget.span?.size ?? 14;

  bool get _isNew => widget.span == null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _TextResult _result({bool delete = false}) =>
      _TextResult(text: _controller.text, size: _size, delete: delete);

  @override
  Widget build(BuildContext context) {
    final span = widget.span;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _isNew ? 'Add text' : 'Edit text',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            span == null
                ? 'Placed in Helvetica'
                : '${span.font} · was ${span.size.toStringAsFixed(1)} pt',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            maxLength: 2000,
            decoration: const InputDecoration(labelText: 'Text'),
            onSubmitted: (_) => Navigator.pop(context, _result()),
          ),
          Row(
            children: [
              const Icon(Icons.format_size, size: 20),
              Expanded(
                child: Slider(
                  value: _size.clamp(4, 120),
                  min: 4,
                  max: 120,
                  divisions: 116,
                  label: '${_size.round()} pt',
                  onChanged: (value) => setState(() => _size = value),
                ),
              ),
              SizedBox(
                width: 54,
                child: Text(
                  '${_size.round()} pt',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          // The embedded font is a subset with no usable character map, so new
          // text has to be drawn in a stand-in. Say so before, not after.
          _Note(
            icon: Icons.font_download_outlined,
            text: 'Replacement text is drawn in a Helvetica stand-in. Position, '
                'size, and colour stay exactly as they are.',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (!_isNew)
                TextButton.icon(
                  onPressed: () => Navigator.pop(context, _result(delete: true)),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, _result()),
                child: Text(_isNew ? 'Place' : 'Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ImageSheet extends StatelessWidget {
  const _ImageSheet({required this.image});

  final EditorImage image;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Image'),
            subtitle: Text('${image.width} × ${image.height} px'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.zoom_out_map),
            title: const Text('Bigger'),
            onTap: () => Navigator.pop(context, 'bigger'),
          ),
          ListTile(
            leading: const Icon(Icons.zoom_in_map),
            title: const Text('Smaller'),
            onTap: () => Navigator.pop(context, 'smaller'),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Replace with another image'),
            subtitle: const Text('Keeps the original position and size.'),
            onTap: () => Navigator.pop(context, 'replace'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove from the page'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final document = controller.document!;
    final saving = controller.saveState.isLoading;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                document.hasEdits
                    ? '${document.operationCount} change'
                        '${document.operationCount == 1 ? '' : 's'} pending'
                    : 'No changes yet',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: saving || controller.isBusy || !document.hasEdits
                  ? null
                  : () => _save(context),
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.download),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await controller.save();
    if (!context.mounted) return;

    switch (controller.saveState) {
      case Success(:final value):
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved ${value.file.name} to ${value.file.location}'),
            duration: const Duration(seconds: 6),
          ),
        );
      case QuotaExceeded(:final error):
        await showPaywall(context, resetsAt: error.resetsAt);
      case Failure(:final error):
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      case _:
        break;
    }
  }
}

class _PageBar extends StatelessWidget {
  const _PageBar({required this.controller, required this.document});

  final EditorController controller;
  final EditorDocument document;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: controller.pageNumber > 1
              ? () => controller.goToPage(controller.pageNumber - 1)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text('Page ${controller.pageNumber} of ${document.pageCount}'),
        IconButton(
          onPressed: controller.pageNumber < document.pageCount
              ? () => controller.goToPage(controller.pageNumber + 1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final placing = controller.placement;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ToolButton(
            icon: Icons.text_fields,
            label: 'Add text',
            active: placing == PlacementMode.text,
            onPressed: controller.isBusy
                ? null
                : () => placing == PlacementMode.text
                    ? controller.cancelPlacing()
                    : controller.startPlacing(PlacementMode.text),
          ),
          const SizedBox(width: 8),
          _ToolButton(
            icon: Icons.add_photo_alternate_outlined,
            label: 'Add image',
            active: placing == PlacementMode.image,
            onPressed: controller.isBusy
                ? null
                : () => placing == PlacementMode.image
                    ? controller.cancelPlacing()
                    : controller.startPlacing(PlacementMode.image),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Filled while armed, so it is obvious the next tap will place something
    // rather than select what is already there.
    return active
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.tertiary,
              foregroundColor: scheme.onTertiary,
            ),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.page, required this.placement});

  final EditorPage page;
  final PlacementMode placement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placing = placement != PlacementMode.none;
    final what = placement == PlacementMode.text ? 'text' : 'image';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Text(
        placing
            ? 'Tap the page where the $what should go.'
            : 'Tap an object to edit it, drag to move it. '
                '${page.spans.length} text, ${page.images.length} image.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: placing ? scheme.tertiary : null,
              fontWeight: placing ? FontWeight.w600 : null,
            ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: child,
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(detail, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 24), action!],
      ],
    );
  }
}
