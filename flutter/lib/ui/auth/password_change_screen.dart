import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../services/localization_service.dart';

class PasswordChangeScreen extends StatefulWidget {
  const PasswordChangeScreen({
    super.key,
    required this.auth,
    required this.locale,
    this.initial = false,
  });
  final AuthProvider auth;
  final LocaleProvider locale;
  final bool initial;

  @override
  State<PasswordChangeScreen> createState() => _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends State<PasswordChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final language = widget.locale.locale.languageCode;
    if (widget.initial) {
      await widget.auth.changeInitialPassword(
        _current.text,
        _next.text,
        language,
      );
    } else {
      await widget.auth.changePassword(_current.text, _next.text, language);
      if (widget.auth.errorMessage == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.of(context).text('password_changed')),
          ),
        );
        _current.clear();
        _next.clear();
        _confirm.clear();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          strings.text(widget.initial ? 'change_password' : 'my_settings'),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.initial) ...[
                        Icon(Icons.lock_reset, size: 40, color: colors.primary),
                        const SizedBox(height: 12),
                        Text(
                          strings.text('first_login_password_note'),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                      ],
                      TextFormField(
                        controller: _current,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: strings.text('current_password'),
                        ),
                        validator: (value) => value == null || value.isEmpty
                            ? strings.text('enter_password')
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _next,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: strings.text('new_password'),
                        ),
                        validator: (value) => value == null || value.length < 10
                            ? strings.text('password_minimum')
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _confirm,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: strings.text('confirm_password'),
                        ),
                        validator: (value) => value != _next.text
                            ? strings.text('passwords_mismatch')
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
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(strings.text('save_password')),
                      ),
                      if (widget.initial)
                        TextButton(
                          onPressed: () => widget.auth.signOut(
                            widget.locale.locale.languageCode,
                          ),
                          child: Text(strings.text('sign_out')),
                        ),
                    ],
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
