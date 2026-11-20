import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../services/organisation_service.dart';
import '../services/super_admin_configuration_service.dart';

class SuperAdminConfigurationProvider extends ChangeNotifier {
  SuperAdminConfigurationProvider({
    required this.organisationService,
    required this.configurationService,
    required this.token,
    required this.language,
    this.onSessionExpired,
  });

  final OrganisationService organisationService;
  final SuperAdminConfigurationService configurationService;
  final String token;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;

  List<OrganisationItem> organisations = [];
  OrganisationItem? selectedOrganisation;
  Map<String, dynamic> configuration = const {};
  bool isLoading = false;
  bool isSaving = false;
  String? error;

  Future<void> loadOrganisations() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      organisations = await organisationService.list(
        token,
        language(),
        limit: 200,
        offset: 0,
      );
      if (organisations.isNotEmpty) {
        selectedOrganisation = organisations.first;
        await loadConfiguration();
      }
    } on AuthException catch (e) {
      _handle(e);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> selectOrganisation(OrganisationItem? value) async {
    selectedOrganisation = value;
    configuration = const {};
    notifyListeners();
    await loadConfiguration();
  }

  Future<void> loadConfiguration() async {
    final organisation = selectedOrganisation;
    if (organisation == null) return;
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      configuration = await configurationService.listForOrganisation(
        token,
        language(),
        organisation.id,
      );
    } on AuthException catch (e) {
      _handle(e);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> validate(
    String kind,
    String code,
    Map<String, dynamic> definition,
  ) async {
    final organisation = selectedOrganisation;
    if (organisation == null) return null;
    isSaving = true;
    error = null;
    notifyListeners();
    try {
      return await configurationService.validate(
        token,
        language(),
        organisation.id,
        kind,
        code,
        definition,
      );
    } on AuthException catch (e) {
      _handle(e);
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> publish(
    String kind,
    String code,
    Map<String, dynamic> definition,
    String reason,
    String effectiveFrom,
  ) async {
    final organisation = selectedOrganisation;
    if (organisation == null) return null;
    isSaving = true;
    error = null;
    notifyListeners();
    try {
      final result = await configurationService.publish(
        token,
        language(),
        organisation.id,
        kind,
        code,
        definition,
        reason,
        effectiveFrom,
      );
      await loadConfiguration();
      return result;
    } on AuthException catch (e) {
      _handle(e);
      return null;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  void _handle(AuthException e) {
    error = e.message;
    if (e.code == 'SESSION_EXPIRED' || e.code == 'ORGANISATION_DISABLED') {
      onSessionExpired?.call(e.message, e.code ?? 'SESSION_EXPIRED');
    }
  }
}
