import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../services/tenant_settings_service.dart';

class TenantSettingsProvider extends ChangeNotifier {
  TenantSettingsProvider(
    this.service,
    this.session,
    this.language, {
    this.onSessionExpired,
  });

  final TenantSettingsService service;
  final AuthSession session;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;
  PageSizeSettings? pageSizeSettings;
  bool isLoading = false;
  bool isSaving = false;
  String? error;

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      pageSizeSettings = await service.getPageSize(session, language());
    } on AuthException catch (e) {
      _handleError(e);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> requestPageSize(int value) async {
    isSaving = true;
    error = null;
    notifyListeners();
    try {
      pageSizeSettings = await service.requestPageSize(
        session,
        language(),
        value,
      );
      return true;
    } on AuthException catch (e) {
      _handleError(e);
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> decide(bool approve) async {
    final settingId = pageSizeSettings?.pendingSettingId;
    if (settingId == null) return false;
    isSaving = true;
    error = null;
    notifyListeners();
    try {
      await service.decidePageSize(session, language(), settingId, approve);
      await load();
      return true;
    } on AuthException catch (e) {
      _handleError(e);
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  void _handleError(AuthException exception) {
    error = exception.message;
    if ({
      'TENANT_ACCESS_INACTIVE',
      'SESSION_EXPIRED',
      'NOT_SIGNED_IN',
      'ORGANISATION_DISABLED',
    }.contains(exception.code)) {
      onSessionExpired?.call(exception.message, exception.code!);
    }
  }
}
