import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';

/// Loads one dashboard summary and tracks loading / error state.
class DashboardProvider<T> extends ChangeNotifier {
  DashboardProvider(
    this.fetch,
    this.token,
    this.language, {
    this.onSessionExpired,
  });

  final Future<T> Function(String token, String language) fetch;
  final String token;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;

  T? data;
  bool isLoading = false;
  String? error;

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      data = await fetch(token, language());
    } on AuthException catch (e) {
      error = e.message;
      if ({'SESSION_EXPIRED', 'NOT_SIGNED_IN'}.contains(e.code)) {
        onSessionExpired?.call(e.message, e.code!);
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
