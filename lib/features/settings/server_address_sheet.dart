import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/server_address.dart';
import '../auth/session_controller.dart';

/// Lets the user point the app at a different backend.
///
/// Reachable from the sign-in screen as well as from Home: if the address is
/// wrong you cannot sign in, so hiding this behind a signed-in settings page
/// would put it out of reach exactly when it is needed.
Future<void> showServerAddressSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _ServerAddressSheet(),
  );
}

class _ServerAddressSheet extends StatefulWidget {
  const _ServerAddressSheet();

  @override
  State<_ServerAddressSheet> createState() => _ServerAddressSheetState();
}

class _ServerAddressSheetState extends State<_ServerAddressSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<ServerAddress>().override ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final address = context.read<ServerAddress>();
    final session = context.read<SessionController>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _saving = true);
    final changed = await address.set(_controller.text);
    if (changed) {
      // Tokens belong to the server that issued them.
      await session.handleServerChanged();
    }

    if (!mounted) return;
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          changed
              ? 'Now using ${address.url}'
              : 'The server address is unchanged.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final address = context.watch<ServerAddress>();
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Server address', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Point the app at the machine running the backend.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 20),

            TextFormField(
              controller: _controller,
              enabled: !_saving,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _saving ? null : _save(),
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.23:8000',
                prefixIcon: const Icon(Icons.dns_outlined),
                helperText: 'Leave blank to use ${address.defaultUrl}',
                helperMaxLines: 2,
              ),
              validator: ServerAddress.validate,
            ),

            const SizedBox(height: 12),
            _Note(
              icon: Icons.info_outline,
              // Both of these surprise people, so say them before they happen.
              text: 'http:// is assumed if you leave the scheme off. Changing '
                  'the server signs you out, because your session belongs to '
                  'the old one.',
            ),

            const SizedBox(height: 20),
            Row(
              children: [
                if (!address.isDefault)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () {
                            _controller.clear();
                            _save();
                          },
                    child: const Text('Reset'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A one-line "current server" control, for screens that want to show it.
class ServerAddressButton extends StatelessWidget {
  const ServerAddressButton({super.key});

  @override
  Widget build(BuildContext context) {
    final address = context.watch<ServerAddress>();

    return TextButton.icon(
      onPressed: () => showServerAddressSheet(context),
      icon: const Icon(Icons.dns_outlined, size: 18),
      label: Text(
        'Server: ${address.label}',
        overflow: TextOverflow.ellipsis,
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
