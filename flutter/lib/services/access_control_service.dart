import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

Map<String, String> _headers(String token, String language) => {
  'Content-Type': 'application/json',
  'Accept': 'application/json',
  'Accept-Language': language,
  'Authorization': 'Bearer $token',
};

class TenantModule {
  const TenantModule({
    required this.code,
    required this.name,
    required this.isEnabled,
    this.isCore = false,
    this.isOptionalLegal = false,
    this.rowVersion,
    this.reason,
  });
  final String code;
  final String name;
  final bool isEnabled;
  final bool isCore;
  final bool isOptionalLegal;
  final int? rowVersion;
  final String? reason;

  factory TenantModule.fromJson(Map<String, dynamic> json) => TenantModule(
    code: json['module_code'] as String,
    name: json['module_name'] as String,
    isEnabled: json['is_enabled'] as bool? ?? false,
    isCore: json['is_core'] as bool? ?? false,
    isOptionalLegal: json['is_optional_legal'] as bool? ?? false,
    rowVersion: json['row_version'] as int?,
    reason: json['reason'] as String?,
  );
}

/// Super Admin: enable or disable an organisation's modules.
class ModuleAccessService {
  ModuleAccessService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);
  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Future<List<TenantModule>> list(
    String token,
    String language,
    String tenantId,
  ) async {
    final response = await _client.get(
      _uri('/super-admin/organisations/$tenantId/modules'),
      headers: _headers(token, language),
    );
    return [
      for (final row in parseApiResponse(response, language) as List<dynamic>)
        TenantModule.fromJson(row as Map<String, dynamic>),
    ];
  }

  Future<TenantModule> setEnabled(
    String token,
    String language,
    String tenantId,
    TenantModule module, {
    required bool enabled,
    required String reason,
    bool legalWarningAck = false,
  }) async {
    final response = await _client.put(
      _uri('/super-admin/organisations/$tenantId/modules/${module.code}'),
      headers: {
        ..._headers(token, language),
        if (module.rowVersion != null)
          'X-Expected-Row-Version': '${module.rowVersion}',
      },
      body: jsonEncode({
        'enabled': enabled,
        'reason': reason,
        'legal_warning_ack': legalWarningAck,
      }),
    );
    return TenantModule.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }
}

class PrivilegeAction {
  const PrivilegeAction(this.code, this.typeCode, this.name, this.protected);
  final String code;
  final String typeCode;
  final String name;
  final bool protected;
}

class MatrixModule {
  const MatrixModule(this.code, this.name, this.actions);
  final String code;
  final String name;
  final List<PrivilegeAction> actions;
}

class MatrixRole {
  const MatrixRole({
    required this.id,
    required this.code,
    required this.name,
    required this.privileges,
    this.isReadOnly = false,
    this.isMyRole = false,
  });
  final String id;
  final String code;
  final String name;
  final Set<String> privileges;
  final bool isReadOnly;
  final bool isMyRole;
}

class RolePrivilegeMatrix {
  const RolePrivilegeMatrix({
    required this.canEdit,
    required this.roles,
    required this.modules,
  });
  final bool canEdit;
  final List<MatrixRole> roles;
  final List<MatrixModule> modules;

  factory RolePrivilegeMatrix.fromJson(Map<String, dynamic> json) =>
      RolePrivilegeMatrix(
        canEdit: json['can_edit'] as bool? ?? false,
        roles: [
          for (final r in json['roles'] as List<dynamic>? ?? const [])
            MatrixRole(
              id: (r as Map<String, dynamic>)['id'] as String,
              code: r['role_code'] as String,
              name: r['role_name'] as String,
              isReadOnly: r['is_read_only'] as bool? ?? false,
              isMyRole: r['is_my_role'] as bool? ?? false,
              privileges: (r['privileges'] as List<dynamic>? ?? const [])
                  .cast<String>()
                  .toSet(),
            ),
        ],
        modules: [
          for (final m in json['modules'] as List<dynamic>? ?? const [])
            MatrixModule(
              (m as Map<String, dynamic>)['module_code'] as String,
              m['module_name'] as String,
              [
                for (final a in m['actions'] as List<dynamic>? ?? const [])
                  PrivilegeAction(
                    (a as Map<String, dynamic>)['privilege_code'] as String,
                    a['type_code'] as String,
                    a['name'] as String,
                    a['protected'] as bool? ?? false,
                  ),
              ],
            ),
        ],
      );
}

/// Privileges that cannot be removed from a role the user holds (lockout).
const roleManagementPrivileges = {'user_role.view', 'user_role.edit'};

/// Whether the screen lets the user tick or untick this cell.
bool canChangePrivilege(
  RolePrivilegeMatrix matrix,
  MatrixRole role,
  PrivilegeAction action,
) {
  if (!matrix.canEdit || action.protected) return false;
  final held = role.privileges.contains(action.code);
  if (!held && role.isReadOnly && !{'V', 'X', 'H'}.contains(action.typeCode)) {
    return false;
  }
  if (held && role.isMyRole && roleManagementPrivileges.contains(action.code)) {
    return false;
  }
  return true;
}

/// Organisation: role x privilege matrix; changes apply immediately.
class RolePrivilegeService {
  RolePrivilegeService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient(config.httpClient);
  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Future<RolePrivilegeMatrix> matrix(String token, String language) async {
    final response = await _client.get(
      _uri('/roles/privileges'),
      headers: _headers(token, language),
    );
    return RolePrivilegeMatrix.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }

  /// Returns whether anything changed.
  Future<bool> setPrivilege(
    String token,
    String language,
    String roleId,
    String privilegeCode, {
    required bool granted,
    String? reason,
  }) async {
    final response = await _client.put(
      _uri('/roles/$roleId/privileges/$privilegeCode'),
      headers: _headers(token, language),
      body: jsonEncode({'granted': granted, 'reason': ?reason}),
    );
    final body = parseApiResponse(response, language) as Map<String, dynamic>;
    return body['changed'] as bool? ?? false;
  }
}
