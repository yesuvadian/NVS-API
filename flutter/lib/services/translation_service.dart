import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

class TranslationService {
  TranslationService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);

  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) => config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Map<String, String> _headers(String token, String language) => {
    'Content-Type': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer $token',
  };

  dynamic _read(http.Response response, String language) =>
      parseApiResponse(response, language);

  Future<List<Map<String, dynamic>>> packs(
    String token,
    String language,
    String targetLanguage,
  ) async =>
      (_read(
            await _client.get(
              _uri('/super-admin/language-packs/$targetLanguage'),
              headers: _headers(token, language),
            ),
            language,
          ) as List)
          .cast<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList();

  Future<int> createDraft(
    String token,
    String language,
    String targetLanguage,
  ) async {
    final row = _read(
      await _client.post(
        _uri('/super-admin/language-packs/$targetLanguage/draft'),
        headers: _headers(token, language),
      ),
      language,
    ) as Map;
    return row['version_no'] as int;
  }

  Future<List<Map<String, dynamic>>> entries(
    String token,
    String language,
    String targetLanguage,
    int version,
    int limit,
    int offset, {
    String? query,
    bool missingOnly = false,
  }) async {
    final uri = _uri(
      '/super-admin/language-packs/$targetLanguage/$version/translations',
    ).replace(
      queryParameters: {
        'limit': '$limit',
        'offset': '$offset',
        if (query?.trim().isNotEmpty == true) 'q': query!.trim(),
        if (missingOnly) 'missing_only': 'true',
      },
    );
    return (_read(
              await _client.get(uri, headers: _headers(token, language)),
              language,
            )
            as List)
        .cast<Map>()
        .map((row) => row.cast<String, dynamic>())
        .toList();
  }

  Future<void> updateEntry(
    String token,
    String language,
    String targetLanguage,
    int version,
    String textId,
    String translatedText,
    String status,
  ) async {
    _read(
      await _client.put(
        _uri(
          '/super-admin/language-packs/$targetLanguage/$version/translations/$textId',
        ),
        headers: _headers(token, language),
        body: jsonEncode({'translated_text': translatedText, 'status': status}),
      ),
      language,
    );
  }

  Future<void> publish(
    String token,
    String language,
    String targetLanguage,
    int version,
  ) async {
    _read(
      await _client.post(
        _uri('/super-admin/language-packs/$targetLanguage/$version/publish'),
        headers: _headers(token, language),
      ),
      language,
    );
  }
}
