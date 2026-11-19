// Live end-to-end tests against a running CFMS API and its database.
// Opt-in: they are skipped unless E2E_LIVE=true. Credentials come from
// --dart-define values on the command line; nothing secret is committed.
//
//   flutter test integration_test/live_e2e_test.dart -d windows \
//     --dart-define=E2E_LIVE=true \
//     --dart-define=E2E_SUPERADMIN_USER=superadmin@example.com \
//     --dart-define=E2E_SUPERADMIN_PASSWORD=... \
//     --dart-define=E2E_ADMIN_USER=admin@demo.example.com \
//     --dart-define=E2E_ADMIN_PASSWORD=... \
//     [--dart-define=E2E_STAFF_USER=emp@demo.example.com --dart-define=E2E_STAFF_PASSWORD=...]
//     [--dart-define=E2E_API_URL=http://127.0.0.1:8000 --dart-define=E2E_TENANT_CODE=demo]
//
// Safe to re-run: the module switched off is always switched back on (also
// when a test fails), and each created member has a unique "E2E Member <time>"
// name and mobile number so it can be recognised later (members cannot be
// deleted through the API).

import 'dart:convert';

import 'package:cfms_portal/app.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

const live = bool.fromEnvironment('E2E_LIVE');
const apiUrl = String.fromEnvironment(
  'E2E_API_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
const tenantCode = String.fromEnvironment(
  'E2E_TENANT_CODE',
  defaultValue: 'demo',
);
const superUser = String.fromEnvironment('E2E_SUPERADMIN_USER');
const superPassword = String.fromEnvironment('E2E_SUPERADMIN_PASSWORD');
const adminUser = String.fromEnvironment('E2E_ADMIN_USER');
const adminPassword = String.fromEnvironment('E2E_ADMIN_PASSWORD');
const staffUser = String.fromEnvironment('E2E_STAFF_USER');
const staffPassword = String.fromEnvironment('E2E_STAFF_PASSWORD');

/// A non-core module with a tenant menu item (Collections).
const toggleModule = String.fromEnvironment(
  'E2E_TOGGLE_MODULE',
  defaultValue: 'LOAN_REPAY',
);
const toggleMenuLabel = String.fromEnvironment(
  'E2E_TOGGLE_MENU',
  defaultValue: 'Collections',
);

final config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse(apiUrl),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'light',
  defaultPageSize: 15,
  maxPageSize: 100,
);

Uri api(String path, [Map<String, String>? query]) =>
    Uri.parse('$apiUrl/api/v1$path').replace(queryParameters: query);

Map<String, String> headers([String? token]) => {
  'Content-Type': 'application/json',
  'Accept-Language': 'en',
  if (token != null) 'Authorization': 'Bearer $token',
};

Future<String> apiLogin(String user, String password) async {
  final response = await http.post(
    api('/auth/login'),
    headers: headers(),
    body: jsonEncode({
      'user_id': user,
      'password': password,
      'channel': 'WEB',
      'force_logout': true,
    }),
  );
  expect(
    response.statusCode,
    200,
    reason: 'API sign-in as $user: ${response.body}',
  );
  return (jsonDecode(response.body) as Map<String, dynamic>)['access_token']
      as String;
}

Future<void> setModule(String token, String tenantId, bool enabled) async {
  final response = await http.put(
    api('/super-admin/organisations/$tenantId/modules/$toggleModule'),
    headers: headers(token),
    body: jsonEncode({
      'enabled': enabled,
      'reason': 'E2E test ${enabled ? 'restore' : 'check'}',
    }),
  );
  expect(response.statusCode, 200, reason: response.body);
}

Future<void> pumpLiveApp(WidgetTester tester) async {
  await tester.pumpWidget(CfmsApp(config: config));
  await tester.pumpAndSettle();
}

Future<void> uiSignIn(WidgetTester tester, String user, String password) async {
  await tester.enterText(find.byType(TextFormField).at(0), user);
  await tester.enterText(find.byType(TextFormField).at(1), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle(const Duration(milliseconds: 200));
  // Single-session organisations ask before signing out another device.
  final force = find.text('Force logout and continue');
  if (force.evaluate().isNotEmpty) {
    await tester.tap(force);
    await tester.pumpAndSettle();
  }
  expect(
    find.byType(NavigationRail),
    findsOneWidget,
    reason: 'signed in as $user',
  );
}

Finder navItem(String label) => find.descendant(
  of: find.byType(NavigationRail),
  matching: find.text(label),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const skip = !live;

  testWidgets('super admin signs in and sees the live platform summary', (
    tester,
  ) async {
    final token = await apiLogin(superUser, superPassword);
    final summary =
        jsonDecode(
              (await http.get(
                api('/super-admin/summary'),
                headers: headers(token),
              )).body,
            )
            as Map<String, dynamic>;
    final total = (summary['organisations'] as Map<String, dynamic>)['total'];

    await pumpLiveApp(tester);
    await uiSignIn(tester, superUser, superPassword);
    expect(find.text('Platform overview'), findsOneWidget);
    expect(find.text('$total'), findsWidgets);
    expect(navItem('Organisations'), findsOneWidget);
  }, skip: skip);

  testWidgets('organisation admin sees the overview and menus', (tester) async {
    await pumpLiveApp(tester);
    await uiSignIn(tester, adminUser, adminPassword);
    expect(find.text('Organisation overview'), findsOneWidget);
    expect(find.text('Active users'), findsOneWidget);
    for (final menu in ['Members', 'Loans', 'Roles & privileges']) {
      expect(navItem(menu), findsOneWidget, reason: menu);
    }
  }, skip: skip);

  testWidgets('a module switched off disappears from the menu, then returns', (
    tester,
  ) async {
    final superToken = await apiLogin(superUser, superPassword);
    final organisations =
        jsonDecode(
              (await http.get(
                api('/super-admin/organisations', {'q': tenantCode}),
                headers: headers(superToken),
              )).body,
            )
            as List<dynamic>;
    final tenantId =
        (organisations.firstWhere((o) => o['code'] == tenantCode) as Map)['id']
            as String;
    addTearDown(() => setModule(superToken, tenantId, true)); // always restore

    await setModule(superToken, tenantId, false);
    await pumpLiveApp(tester);
    await uiSignIn(tester, adminUser, adminPassword);
    expect(navItem(toggleMenuLabel), findsNothing);

    await setModule(superToken, tenantId, true);
    final adminToken = await apiLogin(adminUser, adminPassword);
    final capabilities =
        jsonDecode(
              (await http.get(
                api('/auth/tenant-capabilities'),
                headers: headers(adminToken),
              )).body,
            )
            as Map<String, dynamic>;
    expect(
      (capabilities['modules'] as List).map((m) => m['module_code']),
      contains(toggleModule),
    );
  }, skip: skip);

  testWidgets('staff creates a uniquely named E2E member', (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = 'E2E Member $stamp';
    final mobile = '9${(stamp % 1000000000).toString().padLeft(9, '0')}';

    await pumpLiveApp(tester);
    await uiSignIn(tester, staffUser, staffPassword);
    await tester.tap(navItem('Members'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New member'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Full name'), name);
    await tester.enterText(find.widgetWithText(TextField, 'Mobile'), mobile);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    if (find.text('Possible duplicate member').evaluate().isNotEmpty) {
      await tester.enterText(find.byType(TextField).last, 'E2E test member');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm and save'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Member saved.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search by name, member number or mobile'),
      '$stamp',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(find.text(name), findsOneWidget);
  }, skip: skip || staffUser.isEmpty);
}
