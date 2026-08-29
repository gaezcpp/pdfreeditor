import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/ui/theme.dart';
import 'features/auth/login_page.dart';
import 'features/auth/session_controller.dart';
import 'features/pdf/home_page.dart';

class PdfreeditorApp extends StatelessWidget {
  const PdfreeditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDFree Editor',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const _SessionGate(),
    );
  }
}

/// Chooses the screen from the session phase, so no route can be reached
/// without a live session.
class _SessionGate extends StatelessWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context) {
    final phase = context.select<SessionController, SessionPhase>((s) => s.phase);

    return switch (phase) {
      SessionPhase.starting => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      SessionPhase.signedOut => const LoginPage(),
      SessionPhase.signedIn => const HomePage(),
    };
  }
}
