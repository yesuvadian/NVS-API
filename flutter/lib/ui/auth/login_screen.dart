import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../services/localization_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth, required this.locale});
  final AuthProvider auth;
  final LocaleProvider locale;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userId = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _userId.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final language = widget.locale.locale.languageCode;
    await widget.auth.signIn(_userId.text, _password.text, language);
    if (!mounted || widget.auth.errorCode != 'ACTIVE_SESSION_EXISTS') return;
    final strings = AppStrings.of(context);
    final force = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.text('active_session_title')),
        content: Text(strings.text('active_session_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('force_logout')),
          ),
        ],
      ),
    );
    if (force == true && mounted) {
      await widget.auth.signIn(
        _userId.text,
        _password.text,
        language,
        forceLogout: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final strings = AppStrings.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.account_balance,
                          size: 42,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'CFMS',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          strings.text('sign_in_title'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        TextFormField(
                          controller: _userId,
                          decoration: InputDecoration(
                            labelText: strings.text('user_id'),
                            prefixIcon: const Icon(Icons.person_outline),
                          ),
                          textInputAction: TextInputAction.next,
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? strings.text('enter_user_id')
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _password,
                          decoration: InputDecoration(
                            labelText: strings.text('password'),
                            prefixIcon: const Icon(Icons.lock_outline),
                          ),
                          obscureText: true,
                          onFieldSubmitted: (_) => _submit(),
                          validator: (value) => value == null || value.isEmpty
                              ? strings.text('enter_password')
                              : null,
                        ),
                        if (widget.auth.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            widget.auth.errorMessage!,
                            style: TextStyle(color: colors.error),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: widget.auth.isLoading ? null : _submit,
                          child: widget.auth.isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(strings.text('sign_in')),
                        ),
                        const SizedBox(height: 18),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.center,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: [
                              ButtonSegment(
                                value: 'en',
                                label: Text(strings.text('english')),
                              ),
                              ButtonSegment(
                                value: 'ta',
                                label: Text(strings.text('tamil')),
                              ),
                            ],
                            selected: {widget.locale.locale.languageCode},
                            onSelectionChanged: (selection) =>
                                widget.locale.setLanguage(selection.first),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
