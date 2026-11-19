// A small in-memory CFMS API for widget and mocked integration tests.
// It answers the endpoints the app uses with the same JSON shapes and error
// format (detail.shortCode / detail.message) as the real FastAPI server.

import 'dart:convert';

import 'package:cfms_portal/services/app_config_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeUser {
  FakeUser({
    required this.id,
    required this.login,
    required this.password,
    required this.name,
    this.workspace = 'TENANT',
    this.role,
    this.mustChangePassword = false,
  });
  final String id;
  final String login;
  String password;
  final String name;
  final String workspace;
  final String? role;
  bool mustChangePassword;
}

class FakeMember {
  FakeMember(this.id, this.no, this.fields, {this.status = 'APPLIED'});
  final String id;
  final String no;
  final Map<String, Object?> fields;
  String status;
  int rowVersion = 1;

  Map<String, Object?> toJson() => {
    'id': id,
    'member_no': no,
    'status': status,
    'loan_eligibility': 'ELIGIBLE',
    'preferred_language': 'en',
    'preferred_channel': 'SMS',
    'created_at': '2026-11-19T10:00:00Z',
    ...fields,
    'row_version': rowVersion,
  };
}

http.Response _json(Object? body, [int status = 200]) => http.Response(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(
  int status,
  String code,
  String message, [
  Map<String, Object?>? details,
]) => _json({
  'detail': {
    'code': 'CFMS-TEST',
    'shortCode': code,
    'message': message,
    'language': 'en',
    'retryable': false,
    'details': ?details,
  },
}, status);

class FakeCfmsApi {
  FakeCfmsApi() {
    users = [
      FakeUser(
        id: 'pu-1',
        login: 'superadmin@example.com',
        password: 'Platform@123',
        name: 'Platform Admin',
        workspace: 'SUPER_ADMIN',
      ),
      FakeUser(
        id: 'u-adm',
        login: 'admin@demo.example.com',
        password: 'Welcome@123',
        name: 'Demo Admin',
        role: 'ADM',
        mustChangePassword: true,
      ),
      FakeUser(
        id: 'u-emp',
        login: 'emp@demo.example.com',
        password: 'Staff@12345',
        name: 'Demo Employee',
        role: 'EMP',
      ),
    ];
    rolePrivileges = {
      'ADM': {
        'dash_admin.view',
        'member.view',
        'loan.view',
        'user_role.view',
        'user_role.edit',
        'org.view',
      },
      'EMP': {
        'dash_employee.view',
        'member.view',
        'member.create',
        'member.edit',
      },
    };
    members = [
      FakeMember('m-1', 'MEM-0001', {
        'full_name': 'Anbu Selvan',
        'mobile': '9000000001',
        'city': 'Chennai',
      }, status: 'ACTIVE'),
      FakeMember('m-2', 'MEM-0002', {
        'full_name': 'Kavitha R',
        'mobile': '9000000002',
        'city': 'Madurai',
      }),
      FakeMember('m-3', 'MEM-0003', {
        'full_name': 'Murugan K',
        'mobile': '9000000003',
        'city': 'Salem',
      }),
    ];
  }

  late final List<FakeUser> users;
  late final Map<String, Set<String>> rolePrivileges;
  late final List<FakeMember> members;
  final Map<String, bool> modules = {
    'DASH_ADMIN': true,
    'DASH_EMPLOYEE': true,
    'MEMBER': true,
    'LOAN': true,
    'USER_ROLE': true,
    'ORG': true,
  };
  final Map<String, int> moduleVersions = {};
  final List<http.Request> requests = [];
  final Map<String, Map<String, Object?>> _idempotent = {};
  int pageSize = 2;

  /// Paths this fake should answer with a server error (to test retries).
  final Set<String> failOnce = {};

  AppConfig config({String locale = 'en'}) => AppConfig(
    appName: 'CFMS',
    apiBaseUrl: Uri.parse('http://fake.cfms'),
    apiPrefix: '/api/v1',
    defaultLocale: locale,
    supportedLocales: const ['en', 'ta'],
    themeMode: 'light',
    defaultPageSize: 15,
    maxPageSize: 100,
    httpClient: client,
  );

  late final http.Client client = MockClient(_handle);

  FakeUser? _caller(http.Request request) {
    final header = request.headers['Authorization'] ?? '';
    if (!header.startsWith('Bearer token-')) return null;
    final id = header.substring('Bearer token-'.length);
    return users.where((u) => u.id == id).firstOrNull;
  }

  Map<String, Object?> _session(FakeUser user) => {
    'access_token': 'token-${user.id}',
    'token_type': 'bearer',
    'workspace': user.workspace,
    'must_change_password': user.mustChangePassword,
    'user': {'id': user.id, 'display_name': user.name, 'role': user.role},
  };

  Set<String> _privilegesOf(FakeUser user) => {
    for (final code in rolePrivileges[user.role] ?? const <String>{})
      if (modules[_moduleOf(code)] ?? false) code,
  };

  String _moduleOf(String privilege) =>
      privilege.split('.').first.toUpperCase();

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path.replaceFirst('/api/v1', '');
    if (failOnce.remove('${request.method} $path')) {
      return _error(
        503,
        'SERVICE_UNAVAILABLE',
        'The service is busy. Try again.',
      );
    }
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    if (request.method == 'POST' && path == '/auth/login') {
      final user = users.where((u) => u.login == body['user_id']).firstOrNull;
      if (user == null || user.password != body['password']) {
        return _error(
          401,
          'INVALID_CREDENTIALS',
          'The username or password is incorrect.',
        );
      }
      return _json(_session(user));
    }

    final caller = _caller(request);
    if (caller == null) {
      return _error(401, 'NOT_SIGNED_IN', 'Please sign in to continue.');
    }

    switch ((request.method, path)) {
      case ('POST', '/auth/change-initial-password'):
        if (body['current_password'] != caller.password) {
          return _error(
            401,
            'INVALID_CREDENTIALS',
            'The current password is incorrect.',
          );
        }
        caller
          ..password = body['new_password'] as String
          ..mustChangePassword = false;
        return _json(_session(caller));
      case ('POST', '/auth/logout'):
        return _json(null, 204);
      case ('GET', '/auth/platform-capabilities'):
        return _json({
          'workspace': 'SUPER_ADMIN',
          'permissions': [
            'tenants:can_add',
            'tenants:can_edit',
            'tenants:can_view',
          ],
        });
      case ('GET', '/auth/tenant-capabilities'):
        return _json({
          'role_code': caller.role,
          'privileges': _privilegesOf(caller).toList()..sort(),
          'modules': [
            for (final entry in modules.entries)
              if (entry.value &&
                  _privilegesOf(caller).any((p) => _moduleOf(p) == entry.key))
                {'module_code': entry.key},
          ],
        });
      case ('GET', '/super-admin/summary'):
        return _json({
          'organisations': {
            'total': 3,
            'by_status': {
              'ACTIVE': 2,
              'PROVISIONING': 0,
              'SUSPENDED': 0,
              'CLOSED': 1,
            },
          },
          'newest_organisations': [
            {
              'id': 't-demo',
              'code': 'demo',
              'name': 'Demo Society',
              'status': 'ACTIVE',
              'created_at': '2026-11-18T10:00:00Z',
            },
          ],
        });
      case ('GET', '/super-admin/organisations'):
        return _json([
          {
            'id': 't-demo',
            'code': 'demo',
            'name': 'Demo Society',
            'status': 'ACTIVE',
          },
        ]);
      case ('GET', '/tenant/summary'):
        final privileges = _privilegesOf(caller);
        return _json({
          'working_date': '2026-11-19',
          'sections': [
            if (privileges.contains('member.view')) 'members',
            if (privileges.contains('org.view')) 'administration',
          ],
          if (privileges.contains('member.view'))
            'members': {
              'total': members.length,
              'active': members.where((m) => m.status == 'ACTIVE').length,
            },
          if (privileges.contains('org.view'))
            'administration': {
              'active_users': 2,
              'locked_users': 0,
              'must_change_password': 1,
              'pending_setting_approvals': 0,
            },
        });
      case ('GET', '/tenant-settings/page-size'):
        return _json({
          'page_size': pageSize,
          'pending_setting_id': null,
          'pending_page_size': null,
        });
      case ('GET', '/members'):
        return _listMembers(caller, request.url.queryParameters);
      case ('POST', '/members'):
        return _createMember(caller, request, body);
    }
    final memberMatch = RegExp(r'^/members/([^/]+)$').firstMatch(path);
    if (memberMatch != null) {
      return _member(caller, request, memberMatch.group(1)!, body);
    }
    return _error(404, 'NOT_FOUND', 'Not found: ${request.method} $path');
  }

  http.Response? _deny(FakeUser caller, String privilege) =>
      _privilegesOf(caller).contains(privilege)
      ? null
      : _error(403, 'NO_PRIVILEGE', 'You do not have permission to do this.');

  http.Response _listMembers(FakeUser caller, Map<String, String> query) {
    final denied = _deny(caller, 'member.view');
    if (denied != null) return denied;
    final q = (query['q'] ?? '').toLowerCase();
    final status = query['status'];
    final matching = [
      for (final m in members)
        if ((q.isEmpty ||
                '${m.fields['full_name']} ${m.no} ${m.fields['mobile']}'
                    .toLowerCase()
                    .contains(q)) &&
            (status == null || m.status == status))
          m,
    ];
    final limit = int.parse(query['limit'] ?? '50');
    final offset = int.parse(query['offset'] ?? '0');
    final page = matching.skip(offset).take(limit).toList();
    final hasMore = offset + limit < matching.length;
    return _json({
      'items': [for (final m in page) m.toJson()],
      'limit': limit,
      'offset': offset,
      'has_more': hasMore,
      'next_offset': hasMore ? offset + limit : null,
    });
  }

  http.Response _createMember(
    FakeUser caller,
    http.Request request,
    Map<String, dynamic> body,
  ) {
    final denied = _deny(caller, 'member.create');
    if (denied != null) return denied;
    final key = request.headers['Idempotency-Key'];
    if (key != null && _idempotent.containsKey(key)) {
      return _json(_idempotent[key], 201);
    }
    final mobile = body['mobile'];
    final duplicate = members.any(
      (m) => mobile != null && m.fields['mobile'] == mobile,
    );
    if (duplicate && body['duplicate_override_reason'] == null) {
      return _error(
        409,
        'DUPLICATE_MEMBER',
        'A member with the same mobile number, or the same name and date of birth, already exists.',
      );
    }
    final fields = Map<String, Object?>.of(body)
      ..remove('duplicate_override_reason');
    final member = FakeMember(
      'm-${members.length + 1}',
      'MEM-${(members.length + 1).toString().padLeft(4, '0')}',
      fields,
    );
    members.add(member);
    final json = member.toJson();
    if (key != null) _idempotent[key] = json;
    return _json(json, 201);
  }

  http.Response _member(
    FakeUser caller,
    http.Request request,
    String id,
    Map<String, dynamic> body,
  ) {
    final member = members.where((m) => m.id == id).firstOrNull;
    if (request.method == 'GET') {
      final denied = _deny(caller, 'member.view');
      if (denied != null) return denied;
      return member == null
          ? _error(404, 'MEMBER_NOT_FOUND', 'Member not found.')
          : _json(member.toJson());
    }
    if (request.method == 'PATCH') {
      final denied = _deny(caller, 'member.edit');
      if (denied != null) return denied;
      if (member == null) {
        return _error(404, 'MEMBER_NOT_FOUND', 'Member not found.');
      }
      final expected = int.tryParse(
        request.headers['X-Expected-Row-Version'] ?? '',
      );
      if (expected == null) {
        return _error(
          428,
          'ROW_VERSION_REQUIRED',
          'Send the version of the record you opened.',
        );
      }
      if (expected != member.rowVersion) {
        return _error(
          409,
          'STALE_RECORD',
          'This record was changed after you opened it.',
        );
      }
      member.fields.addAll(Map.of(body)..remove('duplicate_override_reason'));
      member.rowVersion++;
      return _json(member.toJson());
    }
    return _error(405, 'METHOD_NOT_ALLOWED', 'Method not allowed.');
  }

  /// Simulates another user saving the member (bumps its row version).
  void touchMember(String id, {String? city}) {
    final member = members.firstWhere((m) => m.id == id);
    if (city != null) member.fields['city'] = city;
    member.rowVersion++;
  }

  int count(String method, String path) => requests
      .where((r) => r.method == method && r.url.path == '/api/v1$path')
      .length;
}
