import 'package:flutter/foundation.dart';
import '../services/auth_service.dart';
import '../services/organisation_service.dart';

class OrganisationProvider extends ChangeNotifier {
  OrganisationProvider(
    this.service,
    this.token,
    this.language,
    this.pageSize, {
    this.onSessionExpired,
  });
  final OrganisationService service;
  final String token;
  final String Function() language;
  final int pageSize;
  final void Function(String message, String code)? onSessionExpired;
  List<OrganisationItem> organisations = [];
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasMore = true;
  String? error;

  Future<void> load() async {
    isLoading = true;
    error = null;
    hasMore = true;
    organisations = [];
    notifyListeners();
    try {
      final firstPage = await service.list(
        token,
        language(),
        limit: pageSize,
        offset: 0,
      );
      organisations = firstPage;
      hasMore = firstPage.length == pageSize;
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
      final nextPage = await service.list(
        token,
        language(),
        limit: pageSize,
        offset: organisations.length,
      );
      organisations = [...organisations, ...nextPage];
      hasMore = nextPage.length == pageSize;
    } on AuthException catch (e) {
      _setError(e);
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<bool> create(Map<String, dynamic> fields) async {
    try {
      await service.create(token, language(), fields);
      await load();
      return true;
    } on AuthException catch (e) {
      _setError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> setEnabled(OrganisationItem org, bool enabled) async {
    try {
      final tamil = language() == 'ta';
      await service.setEnabled(
        token,
        language(),
        org.id,
        enabled,
        enabled
            ? (tamil
                  ? 'சூப்பர் நிர்வாகியால் மீண்டும் இயக்கப்பட்டது'
                  : 'Re-enabled by Super Administrator')
            : (tamil
                  ? 'சூப்பர் நிர்வாகியால் முடக்கப்பட்டது'
                  : 'Disabled by Super Administrator'),
      );
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
    if ({'SESSION_EXPIRED', 'NOT_SIGNED_IN'}.contains(exception.code)) {
      onSessionExpired?.call(exception.message, exception.code!);
    }
  }
}
