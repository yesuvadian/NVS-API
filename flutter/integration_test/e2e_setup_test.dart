// One-time live setup for live_e2e_test.dart. It creates the tenant through
// the Super Admin Flutter UI, then changes the provisioned Org Admin's first
// password through the Flutter UI. Use a fresh E2E_TENANT_CODE per setup run.
import 'package:cfms_portal/app.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;

import '../test/support/flows.dart' show navItem, tapOn, typeInto;

const live = bool.fromEnvironment('E2E_LIVE');
const apiUrl = String.fromEnvironment(
  'E2E_API_URL',
  defaultValue: 'http://127.0.0.1:8000',
);
const tenantCode = String.fromEnvironment('E2E_TENANT_CODE');
const superUser = String.fromEnvironment('E2E_SUPERADMIN_USER');
const superPassword = String.fromEnvironment('E2E_SUPERADMIN_PASSWORD');
const adminUser = String.fromEnvironment('E2E_ADMIN_USER');
const adminPassword = String.fromEnvironment('E2E_ADMIN_PASSWORD');
const adminFirstLogin = bool.fromEnvironment('E2E_ADMIN_INITIAL');
const initialAdminPassword = 'Welcome@123';
const roleUsers = <String, String>{
  'EMP': 'E2E Community Employee',
  'MGR': 'E2E Manager',
  'ACC': 'E2E Accountant',
  'LDR': 'E2E Leadership',
  'AUD': 'E2E Auditor',
};
const rolePasswords = <String, String>{
  'EMP': String.fromEnvironment('E2E_EMP_PASSWORD'),
  'MGR': String.fromEnvironment('E2E_MGR_PASSWORD'),
  'ACC': String.fromEnvironment('E2E_ACC_PASSWORD'),
  'LDR': String.fromEnvironment('E2E_LDR_PASSWORD'),
  'AUD': String.fromEnvironment('E2E_AUD_PASSWORD'),
};

class SetupHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  String? organisationCreateResponse;
  String? userCreateResponse;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    final bytes = await response.stream.toBytes();
    if (request.method == 'POST' &&
        request.url.path.endsWith('/super-admin/organisations')) {
      organisationCreateResponse =
          'HTTP ${response.statusCode}: ${String.fromCharCodes(bytes)}';
    }
    if (request.method == 'POST' && request.url.path.endsWith('/users')) {
      userCreateResponse =
          'HTTP ${response.statusCode}: ${String.fromCharCodes(bytes)}';
    }
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

final setupHttpClient = SetupHttpClient();
String? setupFormValues;

final config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse(apiUrl),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'light',
  defaultPageSize: 15,
  maxPageSize: 100,
  httpClient: setupHttpClient,
);

Future<void> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CfmsApp(config: config));
  await tester.pumpAndSettle();
}

Future<void> signIn(WidgetTester tester, String user, String password) async {
  await typeInto(tester, find.byType(TextFormField).at(0), user);
  await typeInto(tester, find.byType(TextFormField).at(1), password);
  await tapOn(tester, find.widgetWithText(FilledButton, 'Sign in'));
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var tick = 0; tick < 150 && finder.evaluate().isEmpty; tick++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const skip = !live;

  testWidgets(
    'Super Admin creates the E2E organisation in Flutter UI',
    (tester) async {
      expect(tenantCode, isNotEmpty);
      expect(adminUser, isNotEmpty);
      await pumpApp(tester);
      await signIn(tester, superUser, superPassword);
      expect(find.byType(NavigationRail), findsOneWidget);
      await tapOn(tester, navItem('Organisations'));

      final orgTitle = find.text('Flutter E2E $tenantCode');
      var createdTenant = adminFirstLogin;
      if (orgTitle.evaluate().isEmpty) {
        createdTenant = true;
        await tapOn(tester, find.text('Create organisation').first);
        final orgFields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await typeInto(tester, orgFields.at(0), tenantCode);
        await typeInto(tester, orgFields.at(1), 'Flutter E2E $tenantCode');
        await typeInto(tester, orgFields.at(2), 'Flutter E2E Administrator');
        final stamp = DateTime.now().millisecondsSinceEpoch;
        final mobile = '9${(stamp % 1000000000).toString().padLeft(9, '0')}';
        await typeInto(tester, orgFields.at(3), mobile);
        await typeInto(tester, orgFields.at(4), adminUser);
        await tester.tap(
          find.byKey(const ValueKey('org-loan-repayment-module')),
        );
        await tester.pumpAndSettle();
        setupFormValues = tester
            .widgetList<TextField>(orgFields)
            .map((field) => field.controller?.text ?? '')
            .join(' | ');

        final dialogCreate = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Create organisation'),
        );
        await tapOn(tester, dialogCreate);
        await waitFor(tester, orgTitle);
      }
      expect(
        orgTitle,
        findsOneWidget,
        reason:
            'Response: ${setupHttpClient.organisationCreateResponse}; fields: $setupFormValues; visible Flutter messages: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}',
      );

      // The loan menu needs both the parent LOAN module and repayment module.
      // Open the organisation's module page through Super Admin UI and enable
      // LOAN with the normal reason audit prompt when required.
      await tapOn(tester, orgTitle);
      final loanSwitch = find.byKey(const ValueKey('tenant-module-LOAN'));
      expect(loanSwitch, findsOneWidget);
      if (!tester.widget<SwitchListTile>(loanSwitch).value) {
        await tapOn(tester, loanSwitch);
        await typeInto(
          tester,
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Enable Loan for role navigation E2E',
        );
        await tapOn(tester, find.widgetWithText(FilledButton, 'Save'));
        expect(find.text('Module setting saved.'), findsOneWidget);
        expect(tester.widget<SwitchListTile>(loanSwitch).value, isTrue);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester);
      // Do not probe with a stale password: failed attempts can lock accounts.
      await signIn(
        tester,
        adminUser,
        createdTenant ? initialAdminPassword : adminPassword,
      );
      if (find
          .text('For your security, set a new password before continuing.')
          .evaluate()
          .isNotEmpty) {
        final fields = find.byType(TextFormField);
        await typeInto(tester, fields.at(0), initialAdminPassword);
        await typeInto(tester, fields.at(1), adminPassword);
        await typeInto(tester, fields.at(2), adminPassword);
        await tapOn(tester, find.widgetWithText(FilledButton, 'Save password'));
      }
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Organisation overview'), findsOneWidget);

      // Provision the standard staff roles through the tenant UI. This keeps
      // the live E2E users subject to the same validation and permissions as
      // ordinary Org Admin-created users.
      await tapOn(tester, navItem('User management'));
      for (final entry in roleUsers.entries) {
        final email = '${entry.key.toLowerCase()}@$tenantCode.example.com';
        if (find.textContaining(email).evaluate().isNotEmpty) continue;
        await tapOn(tester, find.text('Create user'));
        final dialog = find.byType(AlertDialog);
        final fields = find.descendant(
          of: dialog,
          matching: find.byType(TextField),
        );
        await typeInto(tester, fields.at(0), entry.value);
        await typeInto(tester, fields.at(1), email);
        await typeInto(
          tester,
          fields.at(2),
          '9${entry.key.codeUnitAt(0)}${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        final roleLabel = switch (entry.key) {
          'EMP' => 'Community Employee',
          'MGR' => 'Manager',
          'ACC' => 'Accountant',
          'LDR' => 'Leadership Team',
          _ => 'Auditor',
        };
        await tapOn(tester, find.text(roleLabel).last);
        await tapOn(
          tester,
          find.descendant(
            of: dialog,
            matching: find.widgetWithText(FilledButton, 'Create user'),
          ),
        );
        await waitFor(tester, find.textContaining(email));
        expect(
          find.textContaining(email),
          findsOneWidget,
          reason:
              'Failed to create ${entry.key} through User Management. Response: ${setupHttpClient.userCreateResponse}. Visible text: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}',
        );
      }

      // Complete each role user's required first-login password change.
      for (final entry in roleUsers.entries) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await pumpApp(tester);
        await signIn(
          tester,
          '${entry.key.toLowerCase()}@$tenantCode.example.com',
          initialAdminPassword,
        );
        expect(
          find.text('For your security, set a new password before continuing.'),
          findsOneWidget,
          reason:
              'first-login password requirement for ${entry.key}. Visible UI: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}',
        );
        final fields = find.byType(TextFormField);
        await typeInto(tester, fields.at(0), initialAdminPassword);
        await typeInto(tester, fields.at(1), rolePasswords[entry.key]!);
        await typeInto(tester, fields.at(2), rolePasswords[entry.key]!);
        await tapOn(tester, find.widgetWithText(FilledButton, 'Save password'));
        await waitFor(tester, find.byType(NavigationRail));
        expect(
          find.byType(NavigationRail),
          findsOneWidget,
          reason:
              'Role ${entry.key} first-login password change did not enter the app. Visible UI: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}',
        );
      }
    },
    skip:
        skip ||
        tenantCode.isEmpty ||
        adminUser.isEmpty ||
        superUser.isEmpty ||
        superPassword.isEmpty,
  );
}
