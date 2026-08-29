import 'package:flutter/material.dart';

import 'user_status.dart';

/// Shows what is left this week, or that the user is premium.
class QuotaCard extends StatelessWidget {
  const QuotaCard({super.key, required this.status, required this.onUpgrade});

  final UserStatus status;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quota = status.quota;

    if (status.isPremium) {
      return Card(
        color: scheme.primaryContainer,
        child: ListTile(
          leading: Icon(Icons.workspace_premium, color: scheme.onPrimaryContainer),
          title: Text(
            'Premium — unlimited edits',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: status.premiumUntil == null
              ? null
              : Text(
                  'Renews ${_formatDate(status.premiumUntil!)}',
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
        ),
      );
    }

    final remaining = quota.remaining ?? 0;
    final exhausted = quota.isExhausted;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    exhausted
                        ? 'No edits left this week'
                        : '$remaining of ${quota.limit} edits left',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  'Resets ${_formatDate(quota.periodEnd)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: quota.fractionUsed,
                minHeight: 8,
                color: exhausted ? scheme.error : scheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onUpgrade,
              icon: const Icon(Icons.workspace_premium_outlined),
              label: const Text('Go unlimited'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Short, local, and unambiguous — "Mon 1 Sep, 07:00".
String _formatDate(DateTime value) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${weekdays[value.weekday - 1]} ${value.day} '
      '${months[value.month - 1]}, $hour:$minute';
}
