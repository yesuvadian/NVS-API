// Widget tests for the Overview dashboards, Roles & privileges grid and the
// Super Admin Modules screen (HTTP faked with MockClient).

import 'dart:convert';

import 'package:cfms_portal/services/access_control_service.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/dashboard_service.dart';
import 'package:cfms_portal/services/localization_service.dart';
import 'package:cfms_portal/ui/super_admin/organisation_modules_screen.dart';
import 'package:cfms_portal/ui/super_admin/super_admin_dashboard.dart';
import 'package:cfms_portal/ui/tenant/roles_privileges_screen.dart';
import 'package:cfms_portal/ui/tenant/tenant_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse('http://fake.cfms'),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'light',
  defaultPageSize: 15,
  maxPageSize: 100,
);

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [AppStrings.delegate],
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Overview dashboards', () {
    testWidgets(
      'super admin dashboard shows live counts and newest organisations',
      (tester) async {
        final service = DashboardService(
          config,
          client: MockClient(
            (_) async => json({
              'organisations': {
                'total': 13,
                'by_status': {
                  'ACTIVE': 1,
                  'PROVISIONING': 0,
                  'SUSPENDED': 0,
                  'CLOSED': 12,
                },
              },
              'newest_organisations': [
                {
                  'id': 't1',
                  'code': 'demo',
                  'name': 'Demo Society',
                  'status': 'ACTIVE',
                  'created_at': '2026-11-18T10:00:00Z',
                },
              ],
            }),
          ),
        );
        await pump(
          tester,
          SuperAdminDashboard(
            service: service,
            token: 'tok',
            language: () => 'en',
          ),
        );

        expect(find.text('13'), findsOneWidget);
        expect(find.text('12'), findsOneWidget);
        expect(find.text('Demo Society'), findsOneWidget);
        expect(find.text('Newest organisations'), findsOneWidget);
      },
    );

    testWidgets('tenant dashboard shows only returned sections', (
      tester,
    ) async {
      final service = DashboardService(
        config,
        client: MockClient(
          (_) async => json({
            'working_date': '2026-11-19',
            'sections': ['members', 'collections'],
            'members': {'total': 5, 'active': 4},
            'collections': {
              'date': '2026-11-19',
              'count': 2,
              'amount': '42500.00',
            },
          }),
        ),
      );
      await pump(
        tester,
        TenantDashboard(service: service, token: 'tok', language: () => 'en'),
      );

      expect(find.text('Members'), findsOneWidget);
      expect(find.text('4 active'), findsOneWidget);
      expect(find.text('₹42,500.00'), findsOneWidget);
      expect(find.text('Approvals pending'), findsNothing);
      expect(find.text('Active users'), findsNothing);
    });

    testWidgets('tenant dashboard empty state', (tester) async {
      final service = DashboardService(
        config,
        client: MockClient((_) async => json({'sections': []})),
      );
      await pump(
        tester,
        TenantDashboard(service: service, token: 'tok', language: () => 'en'),
      );
      expect(
        find.text('Nothing to show on your dashboard yet.'),
        findsOneWidget,
      );
    });

    testWidgets('dashboard error shows message and retries', (tester) async {
      var calls = 0;
      final service = DashboardService(
        config,
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? json({
                  'detail': {
                    'shortCode': 'UNEXPECTED_ERROR',
                    'message': 'Something went wrong.',
                  },
                }, 500)
              : json({
                  'sections': ['members'],
                  'members': {'total': 1, 'active': 1},
                });
        }),
      );
      await pump(
        tester,
        TenantDashboard(service: service, token: 'tok', language: () => 'en'),
      );
      expect(find.text('Something went wrong.'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong.'), findsNothing);
      expect(find.text('1 active'), findsOneWidget);
    });
  });

  group('Roles & privileges', () {
    Map<String, Object?> matrix({bool canEdit = true}) => {
      'can_edit': canEdit,
      'roles': [
        {
          'id': 'r-emp',
          'role_code': 'EMP',
          'role_name': 'Community Employee',
          'privileges': ['member.view'],
        },
        {
          'id': 'r-adm',
          'role_code': 'ADM',
          'role_name': 'System Administrator',
          'is_my_role': true,
          'privileges': ['user_role.view', 'user_role.edit'],
        },
      ],
      'modules': [
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
      ],
    };

    testWidgets('ticking boxes and saving sends one change per privilege', (
      tester,
    ) async {
      final puts = <http.Request>[];
      final service = RolePrivilegeService(
        config,
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            puts.add(request);
            return json({
              'role_id': 'r-emp',
              'role_code': 'EMP',
              'privilege_code': 'x',
              'granted': true,
              'changed': true,
            });
          }
          return json(matrix());
        }),
      );
      await pump(
        tester,
        RolesPrivilegesScreen(
          service: service,
          token: 'tok',
          language: () => 'en',
        ),
      );

      final boxes = find.byType(Checkbox);
      expect(boxes, findsNWidgets(4));
      // EMP: member.view ticked, member.create not.
      expect(tester.widget<Checkbox>(boxes.at(0)).value, isTrue);
      expect(tester.widget<Checkbox>(boxes.at(1)).value, isFalse);

      await tester.tap(boxes.at(1)); // grant member.create
      await tester.tap(boxes.at(0)); // revoke member.view
      await tester.pump();
      expect(find.text('Save changes (2)'), findsOneWidget);
      await tester.tap(find.text('Save changes (2)'));
      await tester.pumpAndSettle();

      expect(puts.map((r) => r.url.path).toSet(), {
        '/api/v1/roles/r-emp/privileges/member.create',
        '/api/v1/roles/r-emp/privileges/member.view',
      });
      expect(puts.map((r) => jsonDecode(r.body)['granted']).toSet(), {
        true,
        false,
      });
    });

    testWidgets('own role management boxes are locked', (tester) async {
      final service = RolePrivilegeService(
        config,
        client: MockClient((_) async => json(matrix())),
      );
      await pump(
        tester,
        RolesPrivilegesScreen(
          service: service,
          token: 'tok',
          language: () => 'en',
        ),
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System Administrator (ADM)').last);
      await tester.pumpAndSettle();

      final boxes = find.byType(Checkbox);
      expect(
        tester.widget<Checkbox>(boxes.at(2)).onChanged,
        isNull,
        reason: 'user_role.view locked',
      );
      expect(
        tester.widget<Checkbox>(boxes.at(3)).onChanged,
        isNull,
        reason: 'user_role.edit locked',
      );
      expect(tester.widget<Checkbox>(boxes.at(0)).onChanged, isNotNull);
    });

    testWidgets('without user_role.edit the grid is read-only', (tester) async {
      final service = RolePrivilegeService(
        config,
        client: MockClient((_) async => json(matrix(canEdit: false))),
      );
      await pump(
        tester,
        RolesPrivilegesScreen(
          service: service,
          token: 'tok',
          language: () => 'en',
        ),
      );
      expect(find.textContaining('Save changes'), findsNothing);
      for (final box in tester.widgetList<Checkbox>(find.byType(Checkbox))) {
        expect(box.onChanged, isNull);
      }
    });
  });

  testWidgets('override privileges appear in an Override column', (
    tester,
  ) async {
    final service = RolePrivilegeService(
      config,
      client: MockClient(
        (_) async => json({
          'can_edit': true,
          'roles': [
            {
              'id': 'r-mgr',
              'role_code': 'MGR',
              'role_name': 'Manager',
              'privileges': ['loan.nominee_override'],
            },
          ],
          'modules': [
            {
              'module_code': 'LOAN',
              'module_name': 'Loans',
              'actions': [
                {
                  'privilege_code': 'loan.view',
                  'type_code': 'V',
                  'name': 'View',
                },
                {
                  'privilege_code': 'loan.nominee_override',
                  'type_code': 'O',
                  'name': 'Nominee override',
                },
              ],
            },
          ],
        }),
      ),
    );
    await pump(
      tester,
      RolesPrivilegesScreen(
        service: service,
        token: 'tok',
        language: () => 'en',
      ),
    );

    expect(find.text('Override'), findsOneWidget);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes, hasLength(2));
    expect(boxes.last.value, isTrue, reason: 'MGR holds loan.nominee_override');
  });

  group('Organisation modules', () {
    testWidgets(
      'switching a module asks for a reason and sends the row version',
      (tester) async {
        final puts = <http.Request>[];
        final service = ModuleAccessService(
          config,
          client: MockClient((request) async {
            if (request.method == 'PUT') {
              puts.add(request);
              return json({
                'module_code': 'LOAN',
                'module_name': 'Loans',
                'is_enabled': false,
                'row_version': 4,
              });
            }
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
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [AppStrings.delegate],
            home: OrganisationModulesScreen(
              service: service,
              token: 'tok',
              language: () => 'en',
              tenantId: 't1',
              organisationName: 'Demo Society',
              canEdit: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final switches = find.byType(Switch);
        expect(
          tester.widget<Switch>(switches.at(0)).onChanged,
          isNull,
          reason: 'core module locked',
        );

        await tester.tap(switches.at(1));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('Enter a reason of at least 3 characters.'),
          findsOneWidget,
        );

        await tester.enterText(
          find.widgetWithText(TextField, 'Reason'),
          'Pause loans',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(puts.single.headers['X-Expected-Row-Version'], '3');
        expect(jsonDecode(puts.single.body)['reason'], 'Pause loans');
        expect(tester.widget<Switch>(switches.at(1)).value, isFalse);
        expect(find.text('Module setting saved.'), findsOneWidget);
      },
    );
  });
}
