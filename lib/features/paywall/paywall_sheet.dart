import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/session_controller.dart';

/// Shows the upgrade sheet.
///
/// [resetsAt] is passed when the sheet was triggered by a `quota_exceeded`
/// response, so the user learns both ways out: upgrade, or wait.
Future<void> showPaywall(BuildContext context, {DateTime? resetsAt}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PaywallSheet(resetsAt: resetsAt),
  );
}

class _PaywallSheet extends StatelessWidget {
  const _PaywallSheet({this.resetsAt});

  final DateTime? resetsAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.workspace_premium, size: 48, color: scheme.primary),
            const SizedBox(height: 16),
            Text('PDFree Premium', textAlign: TextAlign.center, style: textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Unlimited edits, every week.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            const _Benefit(
              icon: Icons.all_inclusive,
              title: 'No weekly limit',
              detail: 'Compress, merge, split, and annotate as much as you need.',
            ),
            const _Benefit(
              icon: Icons.bolt,
              title: 'Priority processing',
              detail: 'Your files skip the quota check entirely.',
            ),
            const _Benefit(
              icon: Icons.description_outlined,
              title: 'Larger documents',
              detail: 'Room for the long reports, not just the short ones.',
            ),

            if (resetsAt != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Not ready to upgrade? Your free edits come back on '
                        '${_formatDate(resetsAt!)}.',
                        style: textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),
            // Store billing is not wired up yet, so this deliberately does not
            // pretend to charge anyone. It refreshes entitlement instead, which
            // is what the real purchase flow will do once it lands.
            FilledButton(
              onPressed: () => _notifyBillingPending(context),
              child: const Text('Upgrade'),
            ),
            const SizedBox(height: 4),
            Text(
              'In-app purchases are not connected yet.',
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _notifyBillingPending(BuildContext context) async {
    final session = context.read<SessionController>();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();

    await session.refreshStatus();
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Billing is not connected yet. Premium can only be granted from the '
          'server for now.',
        ),
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime value) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${value.day} ${months[value.month - 1]}';
}
