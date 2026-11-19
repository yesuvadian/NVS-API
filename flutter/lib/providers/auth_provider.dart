import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider(this._authService);

  final AuthService _authService;
  AuthSession? session;
  bool isLoading = false;
  String? errorMessage;
  String? errorCode;

  Future<void> signIn(
    String userId,
    String password,
    String languageCode, {
    bool forceLogout = false,
  }) async {
    isLoading = true;
    errorMessage = null;
    errorCode = null;
    notifyListeners();
    try {
      var result = await _authService.signIn(
        userId: userId,
        password: password,
        languageCode: languageCode,
        forceLogout: forceLogout,
      );
      if (!result.mustChangePassword) {
        result = result.withCapabilities(
          await _authService.capabilities(
            session: result,
            languageCode: languageCode,
          ),
        );
      }
      session = result;
    } on AuthException catch (error) {
      errorMessage = error.message;
      errorCode = error.code;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> changeInitialPassword(
    String currentPassword,
    String newPassword,
    String languageCode,
  ) async {
    if (session == null) return;
    isLoading = true;
    errorMessage = null;
    errorCode = null;
    notifyListeners();
    try {
      var result = await _authService.changeInitialPassword(
        session: session!,
        currentPassword: currentPassword,
        newPassword: newPassword,
        languageCode: languageCode,
      );
      result = result.withCapabilities(
        await _authService.capabilities(
          session: result,
          languageCode: languageCode,
        ),
      );
      session = result;
    } on AuthException catch (error) {
      errorMessage = error.message;
      errorCode = error.code;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> changePassword(
    String currentPassword,
    String newPassword,
    String languageCode,
  ) async {
    if (session == null) return;
    isLoading = true;
    errorMessage = null;
    errorCode = null;
    notifyListeners();
    try {
      await _authService.changePassword(
        session: session!,
        currentPassword: currentPassword,
        newPassword: newPassword,
        languageCode: languageCode,
      );
    } on AuthException catch (error) {
      errorMessage = error.message;
      errorCode = error.code;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut(String languageCode) async {
    final current = session;
    if (current != null) {
      try {
        await _authService.logout(session: current, languageCode: languageCode);
      } on AuthException catch (error) {
        errorMessage = error.message;
      }
    }
    session = null;
    errorMessage = null;
    errorCode = null;
    notifyListeners();
  }

  Future<void> verifySession(String languageCode) async {
    final current = session;
    if (current == null || current.mustChangePassword || isLoading) return;
    try {
      final capabilities = await _authService.capabilities(
        session: current,
        languageCode: languageCode,
      );
      // Privileges or modules changed by an administrator take effect in the
      // menu here, without signing in again.
      final refreshed = current.withCapabilities(capabilities);
      if (identical(session, current) &&
          (!setEquals(refreshed.permissions, current.permissions) ||
              !setEquals(refreshed.modules, current.modules))) {
        session = refreshed;
        notifyListeners();
      }
    } on AuthException catch (error) {
      if ({
        'SESSION_EXPIRED',
        'NOT_SIGNED_IN',
        'TENANT_ACCESS_INACTIVE',
        'ORGANISATION_DISABLED',
      }.contains(error.code)) {
        session = null;
        errorMessage = error.message;
        notifyListeners();
      }
    }
  }

  void expireSession(
    String localizedMessage, {
    String code = 'TENANT_ACCESS_INACTIVE',
  }) {
    session = null;
    errorMessage = localizedMessage;
    errorCode = code;
    notifyListeners();
  }
}
