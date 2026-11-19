import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

enum WorkspaceRole { superAdmin, tenant }

class AuthSession {
  const AuthSession({
    required this.userId,
    required this.displayName,
    required this.role,
    this.roleCode,
    required this.accessToken,
    required this.mustChangePassword,
    this.permissions = const {},
    this.modules = const {},
  });

  final String userId;
  final String displayName;
  final WorkspaceRole role;
  final String? roleCode;
  final String accessToken;
  final bool mustChangePassword;
  final Set<String> permissions;
  final Set<String> modules;

  AuthSession withCapabilities(Map<String, dynamic> value) => AuthSession(
    userId: userId,
    displayName: displayName,
    role: role,
    roleCode: roleCode,
    accessToken: accessToken,
    mustChangePassword: mustChangePassword,
    permissions:
        ((value['permissions'] ?? value['privileges']) as List<dynamic>? ??
                const [])
            .cast<String>()
            .toSet(),
    modules: (value['modules'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              item is Map ? item['module_code'] as String : item as String,
        )
        .toSet(),
  );
}

abstract interface class AuthService {
  Future<AuthSession> signIn({
    required String userId,
    required String password,
    required String languageCode,
    bool forceLogout = false,
  });
  Future<AuthSession> changeInitialPassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  });
  Future<void> changePassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  });
  Future<void> logout({
    required AuthSession session,
    required String languageCode,
  });
  Future<Map<String, dynamic>> capabilities({
    required AuthSession session,
    required String languageCode,
  });
}

class ApiAuthService implements AuthService {
  ApiAuthService(this.config, {http.Client? client})
    : _client = client ?? http.Client();

  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Map<String, String> _headers(String languageCode, {String? token}) => {
    'Content-Type': 'application/json',
    'Accept-Language': languageCode,
    if (token != null) 'Authorization': 'Bearer $token',
  };

  AuthSession _session(Map<String, dynamic> body) {
    final user = body['user'] as Map<String, dynamic>;
    return AuthSession(
      userId: user['id'] as String,
      displayName: user['display_name'] as String,
      role: body['workspace'] == 'SUPER_ADMIN'
          ? WorkspaceRole.superAdmin
          : WorkspaceRole.tenant,
      roleCode: user['role'] as String?,
      accessToken: body['access_token'] as String,
      mustChangePassword: body['must_change_password'] as bool? ?? false,
    );
  }

  Future<http.Response> _post(
    String path,
    String languageCode, {
    String? token,
    Object? body,
  }) => sendApiRequest(
    () => _client.post(
      _uri(path),
      headers: _headers(languageCode, token: token),
      body: body == null ? null : jsonEncode(body),
    ),
    languageCode,
  );

  @override
  Future<AuthSession> signIn({
    required String userId,
    required String password,
    required String languageCode,
    bool forceLogout = false,
  }) async {
    final response = await _post(
      '/auth/login',
      languageCode,
      body: {
        'user_id': userId.trim(),
        'password': password,
        'channel': 'WEB',
        'force_logout': forceLogout,
      },
    );
    if (response.statusCode != 200) throwApiError(response, languageCode);
    return _session(
      decodeApiBody(response, languageCode) as Map<String, dynamic>,
    );
  }

  @override
  Future<AuthSession> changeInitialPassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  }) async {
    final response = await _post(
      '/auth/change-initial-password',
      languageCode,
      token: session.accessToken,
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
    if (response.statusCode != 200) throwApiError(response, languageCode);
    return _session(
      decodeApiBody(response, languageCode) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> changePassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  }) async {
    final response = await _post(
      '/auth/change-password',
      languageCode,
      token: session.accessToken,
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
    if (response.statusCode != 204) throwApiError(response, languageCode);
  }

  @override
  Future<void> logout({
    required AuthSession session,
    required String languageCode,
  }) async {
    final response = await _post(
      '/auth/logout',
      languageCode,
      token: session.accessToken,
    );
    if (response.statusCode != 204) throwApiError(response, languageCode);
  }

  @override
  Future<Map<String, dynamic>> capabilities({
    required AuthSession session,
    required String languageCode,
  }) async {
    final path = session.role == WorkspaceRole.superAdmin
        ? '/auth/platform-capabilities'
        : '/auth/tenant-capabilities';
    final response = await sendApiRequest(
      () => _client.get(
        _uri(path),
        headers: _headers(languageCode, token: session.accessToken),
      ),
      languageCode,
    );
    if (response.statusCode != 200) throwApiError(response, languageCode);
    return decodeApiBody(response, languageCode) as Map<String, dynamic>;
  }
}

class AuthException implements Exception {
  const AuthException(
    this.message, {
    this.code,
    this.statusCode,
    this.details = const {},
  });
  final String message;
  final String? code;
  final int? statusCode;

  /// The API's `detail.details` object, e.g. `{"errors": [{"field": ...}]}`.
  final Map<String, dynamic> details;

  /// Field name -> message, from `details.errors` of a validation failure.
  Map<String, String> get fieldErrors => {
    for (final error in details['errors'] as List<dynamic>? ?? const [])
      if (error is Map && error['field'] is String)
        (error['field'] as String).split('.').last:
            '${error['message'] ?? message}',
  };
}
