import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_error.dart';
import 'app_config_service.dart';

class OrganisationItem {
  const OrganisationItem(this.id, this.code, this.name, this.status);
  final String id;
  final String code;
  final String name;
  final String status;
  factory OrganisationItem.fromJson(Map<String, dynamic> json) =>
      OrganisationItem(
        json['id'] as String,
        json['code'] as String,
        json['name'] as String,
        json['status'] as String,
      );
}

class OrganisationSetupSetting {
  const OrganisationSetupSetting({
    required this.key,
    required this.area,
    required this.name,
    required this.dataType,
    required this.editableBy,
    required this.defaultValue,
    this.description,
    this.validation,
    this.isProposed = false,
  });
  final String key;
  final String area;
  final String name;
  final String dataType;
  final String editableBy;
  final dynamic defaultValue;
  final String? description;
  final Map<String, dynamic>? validation;
  final bool isProposed;

  factory OrganisationSetupSetting.fromJson(Map<String, dynamic> json) =>
      OrganisationSetupSetting(
        key: json['key'] as String,
        area: json['area'] as String,
        name: json['name'] as String,
        dataType: json['data_type'] as String,
        editableBy: json['editable_by'] as String,
        defaultValue: json['default_value'],
        description: json['description'] as String?,
        validation: (json['validation'] as Map?)?.cast<String, dynamic>(),
        isProposed: json['is_proposed'] as bool? ?? false,
      );
}

class OrganisationSetupModule {
  const OrganisationSetupModule({
    required this.code,
    required this.name,
    required this.isCore,
    required this.isOptionalLegal,
    required this.defaultEnabled,
    this.description,
  });
  final String code;
  final String name;
  final String? description;
  final bool isCore;
  final bool isOptionalLegal;
  final bool defaultEnabled;

  factory OrganisationSetupModule.fromJson(Map<String, dynamic> json) =>
      OrganisationSetupModule(
        code: json['code'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        isCore: json['is_core'] as bool? ?? false,
        isOptionalLegal: json['is_optional_legal'] as bool? ?? false,
        defaultEnabled: json['default_enabled'] as bool? ?? false,
      );
}

class OrganisationSetupFeature {
  const OrganisationSetupFeature({
    required this.code,
    required this.name,
    required this.defaultEnabled,
    this.description,
    this.legalWarning,
  });
  final String code;
  final String name;
  final String? description;
  final String? legalWarning;
  final bool defaultEnabled;

  factory OrganisationSetupFeature.fromJson(Map<String, dynamic> json) =>
      OrganisationSetupFeature(
        code: json['code'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        legalWarning: json['legal_warning'] as String?,
        defaultEnabled: json['default_enabled'] as bool? ?? false,
      );
}

class OrganisationSetupOptions {
  const OrganisationSetupOptions({
    required this.templateVersion,
    required this.defaults,
    required this.modules,
    required this.features,
    required this.settings,
  });
  final int templateVersion;
  final Map<String, dynamic> defaults;
  final List<OrganisationSetupModule> modules;
  final List<OrganisationSetupFeature> features;
  final List<OrganisationSetupSetting> settings;

  factory OrganisationSetupOptions.fromJson(
    Map<String, dynamic> json,
  ) => OrganisationSetupOptions(
    templateVersion: json['settings_template_version'] as int,
    defaults: (json['defaults'] as Map).cast<String, dynamic>(),
    modules: (json['modules'] as List)
        .map(
          (row) =>
              OrganisationSetupModule.fromJson(row as Map<String, dynamic>),
        )
        .toList(),
    features: (json['features'] as List)
        .map(
          (row) =>
              OrganisationSetupFeature.fromJson(row as Map<String, dynamic>),
        )
        .toList(),
    settings: (json['settings'] as List)
        .map(
          (row) =>
              OrganisationSetupSetting.fromJson(row as Map<String, dynamic>),
        )
        .toList(),
  );
}

class OrganisationService {
  OrganisationService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);
  final AppConfig config;
  final http.Client _client;
  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');
  Map<String, String> _headers(String token, String language) => {
    'Content-Type': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer $token',
  };
  dynamic _parse(http.Response response) {
    return parseApiResponse(
      response,
      response.request?.headers['Accept-Language'] ?? 'en',
    );
  }

  Future<OrganisationSetupOptions> setupOptions(
    String token,
    String language,
  ) async {
    final result =
        _parse(
              await _client.get(
                _uri('/super-admin/organisations/setup-options'),
                headers: _headers(token, language),
              ),
            )
            as Map<String, dynamic>;
    return OrganisationSetupOptions.fromJson(result);
  }

  Future<List<OrganisationItem>> list(
    String token,
    String language, {
    required int limit,
    required int offset,
  }) async {
    final uri = _uri(
      '/super-admin/organisations',
    ).replace(queryParameters: {'limit': '$limit', 'offset': '$offset'});
    final rows =
        _parse(await _client.get(uri, headers: _headers(token, language)))
            as List<dynamic>;
    return rows
        .map((row) => OrganisationItem.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<void> create(
    String token,
    String language,
    Map<String, dynamic> fields,
  ) async {
    _parse(
      await _client.post(
        _uri('/super-admin/organisations'),
        headers: _headers(token, language),
        body: jsonEncode(fields),
      ),
    );
  }

  Future<void> setEnabled(
    String token,
    String language,
    String id,
    bool enabled,
    String reason,
  ) async {
    _parse(
      await _client.patch(
        _uri('/super-admin/organisations/$id/status'),
        headers: _headers(token, language),
        body: jsonEncode({'enabled': enabled, 'reason': reason}),
      ),
    );
  }
}
