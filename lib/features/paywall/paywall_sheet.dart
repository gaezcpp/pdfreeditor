import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
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
            if (AppConfig.telegramUsername.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _openContact(
                  context,
                  Uri.parse('https://t.me/${AppConfig.telegramUsername}'),
                ),
                icon: const Icon(Icons.send),
                label: const Text('Upgrade via Telegram'),
              ),
            if (AppConfig.whatsappNumber.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => _openContact(
                  context,
                  Uri.parse(
                    'https://wa.me/${AppConfig.whatsappNumber}?text='
                    '${Uri.encodeComponent('Halo, saya ingin upgrade PDFree Premium.')}',
                  ),
                ),
                icon: const Icon(Icons.chat),
                label: const Text('Upgrade via WhatsApp'),
              ),
            FilledButton(
              onPressed: () => _notifyBillingPending(context),
              child: const Text('Request premium'),
            ),
            const SizedBox(height: 4),
            Text(
              'Premium activation is currently handled by an administrator.',
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

    await session.requestPremium();
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Payment is not connected yet. Ask an administrator to activate '
          'permanent premium for your account.',
        ),
      ),
    );
  }

  Future<void> _openContact(BuildContext context, Uri uri) async {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tidak dapat membuka aplikasi kontak.')),
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
