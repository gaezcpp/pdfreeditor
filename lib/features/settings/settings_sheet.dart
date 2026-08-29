import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/server_address.dart';
import '../../core/files/save_destination.dart';
import 'server_address_sheet.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final address = context.watch<ServerAddress>();
    final destination = context.watch<SaveDestinationStore>();
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Text('Settings', style: theme.textTheme.titleLarge),
            ),

            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server address'),
              subtitle: Text(address.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                showServerAddressSheet(context);
              },
            ),

            // The browser decides where downloads go; there is nothing here for
            // the user to choose, and offering the choice would be a lie.
            if (!kIsWeb) ...[
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text(
                  'Where to save results',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              RadioGroup<SaveDestination>(
                groupValue: destination.value,
                onChanged: (value) {
                  if (value != null) destination.set(value);
                },
                child: Column(
                  children: [
                    for (final option in SaveDestination.values)
                      RadioListTile<SaveDestination>(
                        value: option,
                        title: Text(option.label),
                        subtitle: Text(option.description),
                        isThreeLine: true,
                      ),
                  ],
                ),
              ),
              if (destination.value == SaveDestination.appFolder)
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: _AppFolderWarning(),
                ),
            ],

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _AppFolderWarning extends StatelessWidget {
  const _AppFolderWarning();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'On Android this folder is private to the app. Files saved there '
              'will not appear in your file manager or gallery.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
