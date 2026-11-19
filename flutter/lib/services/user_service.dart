import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';
import 'auth_service.dart';

class ManagedUser {
  const ManagedUser({
    required this.id,
    required this.fullName,
    required this.username,
    required this.roleCode,
    required this.status,
    required this.mustChangePassword,
  });
  final String id;
  final String fullName;
  final String? username;
  final String? roleCode;
  final String status;
  final bool mustChangePassword;

  factory ManagedUser.fromJson(Map<String, dynamic> json) => ManagedUser(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
    username: json['username'] as String?,
    roleCode: json['role_code'] as String?,
    status: json['status'] as String,
    mustChangePassword: json['must_change_password'] as bool,
  );
}

class ManagedRole {
  const ManagedRole(this.code, this.name);
  final String code;
  final String name;
  factory ManagedRole.fromJson(Map<String, dynamic> json) =>
      ManagedRole(json['role_code'] as String, json['role_name'] as String);
}

class UserService {
  UserService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);
  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');
  Map<String, String> _headers(AuthSession session, String language) => {
    'Content-Type': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer ${session.accessToken}',
  };

  Future<dynamic> _request(http.Response response, String language) async {
    return parseApiResponse(response, language);
  }

  Future<List<ManagedUser>> listUsers(
    AuthSession session,
    String language, {
    required int offset,
  }) async {
    final uri = _uri('/users').replace(queryParameters: {'offset': '$offset'});
    final result =
        await _request(
              await _client.get(uri, headers: _headers(session, language)),
              language,
            )
            as List<dynamic>;
    return result
        .map((row) => ManagedUser.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<ManagedRole>> listRoles(
    AuthSession session,
    String language,
  ) async {
    final result =
        await _request(
              await _client.get(
                _uri('/users/roles'),
                headers: _headers(session, language),
              ),
              language,
            )
            as List<dynamic>;
    return result
        .map((row) => ManagedRole.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<void> createUser(
    AuthSession session,
    String language, {
    required String fullName,
    required String roleCode,
    String? email,
    String? mobile,
  }) async {
    await _request(
      await _client.post(
        _uri('/users'),
        headers: _headers(session, language),
        body: jsonEncode({
          'full_name': fullName,
          'role_code': roleCode,
          'email': email,
          'mobile': mobile,
        }),
      ),
      language,
    );
  }

  Future<void> resetPassword(
    AuthSession session,
    String language,
    String userId,
  ) async {
    await _request(
      await _client.post(
        _uri('/users/$userId/password-reset'),
        headers: _headers(session, language),
      ),
      language,
    );
  }
}
