import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

class SuperAdminCatalogueService {
  SuperAdminCatalogueService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);

  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) => config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Map<String, String> _headers(String token, String language) => {
    'Accept': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer $token',
  };

  Future<List<Map<String, dynamic>>> actions(
    String token,
    String language, {
    String? entity,
    String? event,
  }) async {
    final uri = _uri('/super-admin/workflow-actions').replace(
      queryParameters: {
        if (entity != null) 'entity': entity,
        if (event != null) 'event': event,
      },
    );
    final response = await _client.get(uri, headers: _headers(token, language));
    return (parseApiResponse(response, language) as List)
        .cast<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList();
  }

  Future<List<Map<String, dynamic>>> rules(
    String token,
    String language,
  ) async {
    final response = await _client.get(
      _uri('/super-admin/app-rules'),
      headers: _headers(token, language),
    );
    return (parseApiResponse(response, language) as List)
        .cast<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList();
  }
}
