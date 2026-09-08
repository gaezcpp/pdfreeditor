import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/request_state.dart';
import '../settings/server_address_sheet.dart';
import 'session_controller.dart';

/// Sign in and sign up, on one screen with a toggle.
///
/// One form for both keeps the fields, validation, and error surface identical,
/// which is most of what an auth screen gets wrong.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();

  bool _isRegistering = false;
  bool _obscurePassword = true;
  int _serverTaps = 0;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final session = context.read<SessionController>();
    if (_isRegistering) {
      await session.register(
        email: _email.text.trim(),
        password: _password.text,
        fullName: _fullName.text.trim(),
      );
    } else {
      await session.login(email: _email.text.trim(), password: _password.text);
    }
  }

  Future<void> _forgotPassword() async {
    if (!_email.text.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter email first.')),
      );
      return;
    }
    try {
      await context.read<SessionController>().requestPasswordReset(_email.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('If account exists, reset instructions were sent.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not request reset. Try again later.')),
      );
    }
  }

  void _toggleMode() {
    setState(() => _isRegistering = !_isRegistering);
    context.read<SessionController>().clearAuthRequest();
  }

  /// Hidden escape hatch for the server address (tap the logo 5 times).
  ///
  /// The backend now starts with `docker compose up`, so the address field is
  /// deliberately not shown — but a phone on a new network still needs a way
  /// to point at a moved backend without a rebuild.
  void _onLogoTap() {
    _serverTaps++;
    if (_serverTaps >= 5) {
      _serverTaps = 0;
      showServerAddressSheet(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final request = session.authRequest;
    final isBusy = request.isLoading;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      onTap: _onLogoTap,
                      child: Icon(
                        Icons.picture_as_pdf,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'PDFree Editor',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isRegistering
                          ? 'Create an account to start editing.'
                          : 'Sign in to continue.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 32),

                    if (session.expiryNotice != null) ...[
                      _Notice(message: session.expiryNotice!),
                      const SizedBox(height: 16),
                    ],

                    if (_isRegistering) ...[
                      TextFormField(
                        controller: _fullName,
                        enabled: !isBusy,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Name (optional)',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    TextFormField(
                      controller: _email,
                      enabled: !isBusy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _password,
                      enabled: !isBusy,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => isBusy ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                    if (!_isRegistering)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: isBusy ? null : _forgotPassword,
                          child: const Text('Forgot password?'),
                        ),
                      ),

                    if (request case Failure(:final error)) ...[
                      const SizedBox(height: 16),
                      _Notice(message: error.message, isError: true),
                    ],

                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: isBusy ? null : _submit,
                      child: isBusy
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            )
                          : Text(_isRegistering ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: isBusy ? null : _toggleMode,
                      child: Text(
                        _isRegistering
                            ? 'Already have an account? Sign in'
                            : "New here? Create an account",
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email.';
    // Deliberately loose: the backend is the authority on deliverability.
    if (!email.contains('@') || !email.contains('.')) {
      return 'That does not look like an email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter your password.';
    // Only enforced on sign-up; an existing password may predate the rule.
    if (_isRegistering && password.length < 8) {
      return 'Use at least 8 characters.';
    }
    return null;
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground =
        isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 20,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: TextStyle(color: foreground))),
        ],
      ),
    );
  }
}
