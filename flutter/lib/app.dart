import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:async';

import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'services/app_config_service.dart';
import 'services/auth_service.dart';
import 'services/localization_service.dart';
import 'ui/auth/login_screen.dart';
import 'ui/auth/password_change_screen.dart';
import 'ui/shared/app_shell.dart';
import 'ui/theme/app_theme.dart';

class CfmsApp extends StatefulWidget {
  const CfmsApp({super.key, required this.config});
  final AppConfig config;

  @override
  State<CfmsApp> createState() => _CfmsAppState();
}

class _CfmsAppState extends State<CfmsApp> {
  late final AuthProvider _auth = AuthProvider(ApiAuthService(widget.config));
  late final LocaleProvider _locale = LocaleProvider(
    widget.config.defaultLocale,
  );
  // Checks every 30 seconds that the session is still valid, so a force
  // logout from another device or a disabled organisation signs the user out.
  late final Timer _sessionMonitor;

  @override
  void initState() {
    super.initState();
    _sessionMonitor = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _auth.verifySession(_locale.locale.languageCode),
    );
  }

  @override
  void dispose() {
    _sessionMonitor.cancel();
    _auth.dispose();
    _locale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = switch (widget.config.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    return AnimatedBuilder(
      animation: Listenable.merge([_auth, _locale]),
      builder: (context, _) => MaterialApp(
        title: widget.config.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: themeMode,
        locale: _locale.locale,
        supportedLocales: [
          for (final language in widget.config.supportedLocales)
            Locale(language),
        ],
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _auth.session == null
            ? LoginScreen(auth: _auth, locale: _locale)
            : _auth.session!.mustChangePassword
            ? PasswordChangeScreen(auth: _auth, locale: _locale, initial: true)
            : AppShell(
                auth: _auth,
                session: _auth.session!,
                locale: _locale,
                config: widget.config,
              ),
      ),
    );
  }
}
