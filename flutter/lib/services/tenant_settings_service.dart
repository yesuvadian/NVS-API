import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';
import 'auth_service.dart';

class PageSizeSettings {
  const PageSizeSettings({
    required this.pageSize,
    this.pendingSettingId,
    this.pendingPageSize,
    this.status = 'ACTIVE',
  });

  final int pageSize;
  final String? pendingSettingId;
  final int? pendingPageSize;
  final String status;

  factory PageSizeSettings.fromJson(Map<String, dynamic> json) =>
      PageSizeSettings(
        pageSize: json['page_size'] as int? ?? 15,
        pendingSettingId: json['pending_setting_id'] as String?,
        pendingPageSize: json['pending_page_size'] as int?,
        status: json['status'] as String? ?? 'ACTIVE',
      );
}

class TenantSettingsService {
  TenantSettingsService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);

  final AppConfig config;
  final http.Client _client;
  Uri _uri() => config.apiBaseUrl.resolve(
    '${config.apiPrefix}/tenant-settings/page-size',
  );
  Map<String, String> _headers(AuthSession session, String language) => {
    'Content-Type': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer ${session.accessToken}',
  };

  Future<PageSizeSettings> getPageSize(
    AuthSession session,
    String language,
  ) async {
    final response = await _client.get(
      _uri(),
      headers: _headers(session, language),
    );
    return PageSizeSettings.fromJson(
      await _parse(response, language) as Map<String, dynamic>,
    );
  }

  Future<PageSizeSettings> requestPageSize(
    AuthSession session,
    String language,
    int pageSize,
  ) async {
    final response = await _client.put(
      _uri(),
      headers: _headers(session, language),
      body: jsonEncode({'page_size': pageSize}),
    );
    return PageSizeSettings.fromJson(
      await _parse(response, language) as Map<String, dynamic>,
    );
  }

  Future<void> decidePageSize(
    AuthSession session,
    String language,
    String settingId,
    bool approve,
  ) async {
    final uri = config.apiBaseUrl.resolve(
      '${config.apiPrefix}/tenant-settings/page-size/$settingId/decision',
    );
    final response = await _client.post(
      uri,
      headers: _headers(session, language),
      body: jsonEncode({'approve': approve}),
    );
    await _parse(response, language);
  }

  Future<dynamic> _parse(http.Response response, String language) async {
    return parseApiResponse(response, language);
  }
}
