import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

class SuperAdminConfigurationService {
  SuperAdminConfigurationService(this.config, {http.Client? client})
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

  dynamic _parse(http.Response response) => parseApiResponse(
    response,
    response.request?.headers['Accept-Language'] ?? 'en',
  );

  Future<Map<String, dynamic>> listForOrganisation(
    String token,
    String language,
    String tenantId,
  ) async =>
      (_parse(
                await _client.get(
                  _uri('/super-admin/organisations/$tenantId/configurations'),
                  headers: _headers(token, language),
                ),
              )
              as Map)
          .cast<String, dynamic>();

  Future<Map<String, dynamic>> validate(
    String token,
    String language,
    String tenantId,
    String kind,
    String code,
    Map<String, dynamic> definition,
  ) async =>
      (_parse(
                await _client.post(
                  _uri(
                    '/super-admin/organisations/$tenantId/configurations/validate',
                  ),
                  headers: _headers(token, language),
                  body: jsonEncode({
                    'kind': kind,
                    'code': code,
                    'definition': definition,
                  }),
                ),
              )
              as Map)
          .cast<String, dynamic>();

  Future<Map<String, dynamic>> publish(
    String token,
    String language,
    String tenantId,
    String kind,
    String code,
    Map<String, dynamic> definition,
    String reason,
    String effectiveFrom,
  ) async =>
      (_parse(
                await _client.post(
                  _uri(
                    '/super-admin/organisations/$tenantId/configurations/publish',
                  ),
                  headers: _headers(token, language),
                  body: jsonEncode({
                    'kind': kind,
                    'code': code,
                    'definition': definition,
                    'reason': reason,
                    'effective_from': effectiveFrom,
                  }),
                ),
              )
              as Map)
          .cast<String, dynamic>();
}
