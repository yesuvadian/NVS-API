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
