import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/session_controller.dart';
import '../editor/editor_page.dart';
import '../paywall/paywall_sheet.dart';
import '../settings/settings_sheet.dart';
import '../user/quota_card.dart';
import 'pdf_tool.dart';
import 'tool_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final status = session.status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PDFree Editor'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => showSettingsSheet(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () => _confirmSignOut(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: session.refreshStatus,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (status != null) ...[
              Text(
                'Hello, ${status.user.displayName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              QuotaCard(
                status: status,
                onUpgrade: () => showPaywall(context),
              ),
              const SizedBox(height: 24),
            ],
            Text('Edit', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const _EditorTile(),
            const SizedBox(height: 24),
            Text(
              'Whole-file tools',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final tool in PdfTool.values) ...[
              _ToolTile(tool: tool),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final session = context.read<SessionController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to edit PDFs.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await session.logout();
  }
}

/// The way in to the WYSIWYG editor, kept apart from the whole-file tools:
/// it changes what is *on* a page rather than transforming the document.
class _EditorTile extends StatelessWidget {
  const _EditorTile();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: scheme.primaryContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: CircleAvatar(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          child: const Icon(Icons.edit_document),
        ),
        title: Text(
          'Edit text and images',
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'Open a PDF, tap any word or picture, and change it.',
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const EditorPageScreen()),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});

  final PdfTool tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          child: Icon(tool.icon),
        ),
        title: Text(tool.label),
        subtitle: Text(tool.description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => ToolPage(tool: tool)),
        ),
      ),
    );
  }
}
