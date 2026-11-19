import 'dart:convert';

import 'package:cfms_portal/providers/auth_provider.dart';
import 'package:cfms_portal/services/access_control_service.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:cfms_portal/ui/shared/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse('http://localhost:8000'),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'system',
  defaultPageSize: 15,
  maxPageSize: 100,
);

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AuthSession tenant({
  Set<String> permissions = const {},
  Set<String> modules = const {},
  String roleCode = 'EMP',
}) => AuthSession(
  userId: 'u1',
  displayName: 'User',
  role: WorkspaceRole.tenant,
  roleCode: roleCode,
  accessToken: 'tok',
  mustChangePassword: false,
  permissions: permissions,
  modules: modules,
);

List<String> menu(AuthSession session) =>
    navItemsFor(session).map((item) => item.key).toList();

class FakeAuthService implements AuthService {
  FakeAuthService(this.capabilitiesResult);
  Map<String, dynamic> capabilitiesResult;

  @override
  Future<Map<String, dynamic>> capabilities({
    required AuthSession session,
    required String languageCode,
  }) async => capabilitiesResult;

  @override
  Future<AuthSession> signIn({
    required String userId,
    required String password,
    required String languageCode,
    bool forceLogout = false,
  }) async => tenant(permissions: {'member.view'}, modules: {'MEMBER'});

  @override
  Future<AuthSession> changeInitialPassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  }) async => session;

  @override
  Future<void> changePassword({
    required AuthSession session,
    required String currentPassword,
    required String newPassword,
    required String languageCode,
  }) async {}

  @override
  Future<void> logout({
    required AuthSession session,
    required String languageCode,
  }) async {}
}

void main() {
  group('side menu filtering', () {
    test('needs both the privilege and the enabled module', () {
      expect(
        menu(tenant(permissions: {'member.view'})),
        isNot(contains('nav_members')),
      );
      expect(menu(tenant(modules: {'MEMBER'})), isNot(contains('nav_members')));
      expect(
        menu(tenant(permissions: {'member.view'}, modules: {'MEMBER'})),
        contains('nav_members'),
      );
    });

    test('a disabled module hides its menu even with the privilege', () {
      final session = tenant(
        permissions: {'member.view', 'loan.view'},
        modules: {'MEMBER'},
      );
      expect(menu(session), contains('nav_members'));
      expect(menu(session), isNot(contains('nav_loans')));
    });

    test('collections show for viewers; roles screen needs user_role.view', () {
      final viewer = tenant(
        permissions: {'loan_repay.view', 'user_role.view'},
        modules: {'LOAN_REPAY', 'USER_ROLE'},
      );
      expect(
        menu(viewer),
        containsAll(['nav_collections', 'nav_roles', 'user_management']),
      );
      expect(
        menu(tenant(modules: {'USER_ROLE'})),
        isNot(contains('nav_roles')),
      );
    });

    test('overview follows the dashboard module; my settings always shows', () {
      expect(menu(tenant(modules: {'DASH_ADMIN'})).first, 'nav_overview');
      expect(menu(tenant()), ['nav_my_settings']);
    });

    test('super admin menu is gated by platform permissions', () {
      const admin = AuthSession(
        userId: 'p1',
        displayName: 'Super',
        role: WorkspaceRole.superAdmin,
        accessToken: 'tok',
        mustChangePassword: false,
        permissions: {'tenants:can_view'},
      );
      expect(menu(admin), ['nav_overview', 'nav_organisations']);
    });
  });

  group('module access service', () {
    test(
      'lists modules and sends the expected row version on change',
      () async {
        final requests = <http.Request>[];
        final service = ModuleAccessService(
          config,
          client: MockClient((request) async {
            requests.add(request);
            if (request.method == 'GET') {
              return json([
                {
                  'module_code': 'MEMBER',
                  'module_name': 'Members',
                  'is_enabled': true,
                  'is_core': true,
                  'row_version': 1,
                },
                {
                  'module_code': 'LOAN',
                  'module_name': 'Loans',
                  'is_enabled': true,
                  'row_version': 3,
                },
              ]);
            }
            return json({
              'module_code': 'LOAN',
              'module_name': 'Loans',
              'is_enabled': false,
              'row_version': 4,
            });
          }),
        );

        final modules = await service.list('tok', 'en', 't1');
        expect(modules.first.isCore, isTrue);
        final updated = await service.setEnabled(
          'tok',
          'en',
          't1',
          modules.last,
          enabled: false,
          reason: 'Pause loans',
        );

        expect(updated.isEnabled, isFalse);
        expect(updated.rowVersion, 4);
        final put = requests.last;
        expect(put.method, 'PUT');
        expect(
          put.url.path,
          '/api/v1/super-admin/organisations/t1/modules/LOAN',
        );
        expect(put.headers['X-Expected-Row-Version'], '3');
        expect(jsonDecode(put.body), {
          'enabled': false,
          'reason': 'Pause loans',
          'legal_warning_ack': false,
        });
      },
    );
  });

  group('role privilege service', () {
    final matrixJson = {
      'can_edit': true,
      'roles': [
        {
          'id': 'r-adm',
          'role_code': 'ADM',
          'role_name': 'Admin',
          'is_my_role': true,
          'privileges': ['user_role.edit', 'user_role.view'],
        },
        {
          'id': 'r-aud',
          'role_code': 'AUD',
          'role_name': 'Auditor',
          'is_read_only': true,
          'privileges': ['member.view'],
        },
      ],
      'modules': [
        {
          'module_code': 'USER_ROLE',
          'module_name': 'Users & roles',
          'actions': [
            {
              'privilege_code': 'user_role.view',
              'type_code': 'V',
              'name': 'View',
            },
            {
              'privilege_code': 'user_role.edit',
              'type_code': 'E',
              'name': 'Edit',
            },
          ],
        },
        {
          'module_code': 'MEMBER',
          'module_name': 'Members',
          'actions': [
            {'privilege_code': 'member.view', 'type_code': 'V', 'name': 'View'},
            {
              'privilege_code': 'member.create',
              'type_code': 'C',
              'name': 'Create',
            },
          ],
        },
        {
          'module_code': 'WORKFLOW',
          'module_name': 'Workflows',
          'actions': [
            {
              'privilege_code': 'workflow.edit',
              'type_code': 'E',
              'name': 'Edit',
              'protected': true,
            },
          ],
        },
      ],
    };

    test('parses the matrix and applies the cell rules', () async {
      final service = RolePrivilegeService(
        config,
        client: MockClient((_) async => json(matrixJson)),
      );
      final matrix = await service.matrix('tok', 'en');
      final adm = matrix.roles.first;
      final aud = matrix.roles.last;
      PrivilegeAction action(String code) => matrix.modules
          .expand((m) => m.actions)
          .firstWhere((a) => a.code == code);

      expect(adm.privileges, contains('user_role.edit'));
      // Own role management cannot be removed (lockout).
      expect(
        canChangePrivilege(matrix, adm, action('user_role.edit')),
        isFalse,
      );
      expect(canChangePrivilege(matrix, adm, action('member.view')), isTrue);
      // Read-only role: view yes, create no.
      expect(canChangePrivilege(matrix, aud, action('member.create')), isFalse);
      expect(canChangePrivilege(matrix, aud, action('member.view')), isTrue);
      // Platform-protected.
      expect(canChangePrivilege(matrix, adm, action('workflow.edit')), isFalse);
      // Without user_role.edit nothing is editable.
      final readOnlyMatrix = RolePrivilegeMatrix(
        canEdit: false,
        roles: matrix.roles,
        modules: matrix.modules,
      );
      expect(
        canChangePrivilege(readOnlyMatrix, aud, action('member.view')),
        isFalse,
      );
    });

    test(
      'grant/revoke sends one PUT per privilege and reports the server code',
      () async {
        late http.Request seen;
        final service = RolePrivilegeService(
          config,
          client: MockClient((request) async {
            seen = request;
            if (request.url.path.endsWith('user_role.edit')) {
              return json({
                'detail': {
                  'shortCode': 'ROLE_ADMIN_LOCKOUT',
                  'message':
                      'You cannot remove role management from your own role.',
                },
              }, 409);
            }
            return json({
              'role_id': 'r-emp',
              'role_code': 'EMP',
              'privilege_code': 'member.view',
              'granted': false,
              'changed': true,
            });
          }),
        );

        expect(
          await service.setPrivilege(
            'tok',
            'en',
            'r-emp',
            'member.view',
            granted: false,
          ),
          isTrue,
        );
        expect(seen.method, 'PUT');
        expect(seen.url.path, '/api/v1/roles/r-emp/privileges/member.view');
        expect(jsonDecode(seen.body), {'granted': false});

        expect(
          () => service.setPrivilege(
            'tok',
            'en',
            'r-adm',
            'user_role.edit',
            granted: false,
          ),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'ROLE_ADMIN_LOCKOUT',
            ),
          ),
        );
      },
    );
  });

  test('session check refreshes privileges so the menu updates', () async {
    final fake = FakeAuthService({
      'privileges': ['member.view'],
      'modules': ['MEMBER'],
    });
    final auth = AuthProvider(fake);
    await auth.signIn('emp', 'secret', 'en');
    expect(menu(auth.session!), contains('nav_members'));
    var notified = 0;
    auth.addListener(() => notified++);

    await auth.verifySession('en');
    expect(notified, 0, reason: 'unchanged privileges do not rebuild');

    fake.capabilitiesResult = {
      'privileges': <String>[],
      'modules': ['MEMBER'],
    };
    await auth.verifySession('en');
    expect(notified, 1);
    expect(menu(auth.session!), isNot(contains('nav_members')));
  });
}
