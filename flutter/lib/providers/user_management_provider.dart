import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../services/user_service.dart';
import '../services/tenant_settings_service.dart';

class UserManagementProvider extends ChangeNotifier {
  UserManagementProvider(
    this.service,
    this.settingsService,
    this.session,
    this.language, {
    this.onSessionExpired,
  });
  final UserService service;
  final TenantSettingsService settingsService;
  final AuthSession session;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;
  List<ManagedUser> users = [];
  List<ManagedRole> roles = [];
  int pageSize = 15;
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasMore = true;
  String? error;

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      final lang = language();
      final settings = await settingsService.getPageSize(session, lang);
      pageSize = settings.pageSize;
      final results = await Future.wait([
        service.listUsers(session, lang, offset: 0),
        service.listRoles(session, lang),
      ]);
      users = results[0] as List<ManagedUser>;
      roles = results[1] as List<ManagedRole>;
      hasMore = users.length == pageSize;
    } on AuthException catch (e) {
      _setError(e);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (isLoading || isLoadingMore || !hasMore) return;
    isLoadingMore = true;
    error = null;
    notifyListeners();
    try {
      final next = await service.listUsers(
        session,
        language(),
        offset: users.length,
      );
      users = [...users, ...next];
      hasMore = next.length == pageSize;
    } on AuthException catch (e) {
      _setError(e);
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<bool> create({
    required String name,
    required String role,
    String? email,
    String? mobile,
  }) async {
    try {
      await service.createUser(
        session,
        language(),
        fullName: name,
        roleCode: role,
        email: email,
        mobile: mobile,
      );
      await load();
      return true;
    } on AuthException catch (e) {
      _setError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> reset(String userId) async {
    try {
      await service.resetPassword(session, language(), userId);
      await load();
      return true;
    } on AuthException catch (e) {
      _setError(e);
      notifyListeners();
      return false;
    }
  }

  void _setError(AuthException exception) {
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
