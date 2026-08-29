import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/ui/theme.dart';

/// Layout regressions in the shared button theme.
///
/// A theme-level `minimumSize` applies to every button in the app, so getting
/// it wrong breaks screens far from where it was written. `Size.fromHeight(h)`
/// reads like "full width" but is `Size(infinity, h)`: any parent that offers
/// unbounded width — a Row, a dialog's action bar, a bottom bar — then throws
/// "BoxConstraints forces an infinite width" and the whole app renders blank.
Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('a button in a Row lays out to a finite width', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Row(
          children: [
            const Expanded(child: Text('2 changes pending')),
            FilledButton(onPressed: () {}, child: const Text('Save')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(FilledButton));
    expect(size.width, lessThan(600));
    expect(size.height, greaterThanOrEqualTo(52));
  });

  testWidgets('a button in a bottom bar Row lays out', (tester) async {
    // The exact shape of the editor's save bar.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Expanded(child: Text('No changes yet')),
                  FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.download),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a button in a dialog action bar lays out', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Sign out?'),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Cancel')),
                  FilledButton(onPressed: () {}, child: const Text('Sign out')),
                ],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sign out?'), findsOneWidget);
  });

  testWidgets('a stretching parent still gives a full-width button',
      (tester) async {
    // Sign-in and the paywall rely on this, and the fix must not cost it.
    await tester.pumpWidget(
      _wrap(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(onPressed: () {}, child: const Text('Sign in')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(FilledButton));
    expect(size.width, tester.view.physicalSize.width / tester.view.devicePixelRatio);
  });
}
