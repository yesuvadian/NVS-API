import 'dart:convert';

import 'package:flutter/services.dart';

class AppConfig {
  const AppConfig({
    required this.appName,
    required this.apiBaseUrl,
    required this.apiPrefix,
    required this.defaultLocale,
    required this.supportedLocales,
    required this.themeMode,
    required this.defaultPageSize,
    required this.maxPageSize,
  });

  final String appName;
  final Uri apiBaseUrl;
  final String apiPrefix;
  final String defaultLocale;
  final List<String> supportedLocales;
  final String themeMode;
  final int defaultPageSize;
  final int maxPageSize;

  static Future<AppConfig> load() async {
    final envText = await rootBundle.loadString('.env');
    final env = <String, String>{};
    for (final rawLine in envText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
      final separator = line.indexOf('=');
      env[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trim();
    }

    final jsonText = await rootBundle.loadString('config.json');
    final config = jsonDecode(jsonText) as Map<String, dynamic>;
    final baseUrl = env['CFMS_API_BASE_URL'];
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('CFMS_API_BASE_URL is required in flutter/.env');
    }

    return AppConfig(
      appName: config['appName'] as String,
      apiBaseUrl: Uri.parse(baseUrl),
      apiPrefix: config['apiPrefix'] as String,
      defaultLocale: config['defaultLocale'] as String,
      supportedLocales: (config['supportedLocales'] as List<dynamic>)
          .cast<String>(),
      themeMode: config['themeMode'] as String,
      defaultPageSize: config['defaultPageSize'] as int,
      maxPageSize: config['maxPageSize'] as int,
    );
  }
}
