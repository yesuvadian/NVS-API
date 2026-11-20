// End-to-end app flows against the in-memory FakeCfmsApi. Shared by the
// widget tests (test/app_flows_test.dart, run with `flutter test`) and the
// mocked integration tests (integration_test/app_flows_test.dart, run on a
// device), so both layers exercise exactly the same journeys.

import 'package:cfms_portal/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

Future<void> pumpApp(
  WidgetTester tester,
  FakeCfmsApi api, {
  Duration sessionCheck = const Duration(hours: 1),
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CfmsApp(config: api.config(), sessionCheckInterval: sessionCheck),
  );
  await tester.pumpAndSettle();
}

Future<void> signIn(WidgetTester tester, String login, String password) async {
  await typeInto(tester, find.byType(TextFormField).at(0), login);
  await typeInto(tester, find.byType(TextFormField).at(1), password);
  await tapOn(tester, find.widgetWithText(FilledButton, 'Sign in'));
}

/// Scrolls [finder] into view (real device windows can be smaller than the
/// test view), taps it and waits for the UI to settle.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Scrolls a text field into view before typing, so focus lands on it.
Future<void> typeInto(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  // Focus first: on a device the field may still hold focus from before,
  // and enterText alone does not always reconnect the text input.
  await tester.tap(finder);
  await tester.pump();
  await tester.enterText(finder, text);
  await tester.pump();
}

Finder navItem(String label) => find.descendant(
  of: find.byType(NavigationRail),
  matching: find.text(label),
);

Future<void> openNav(WidgetTester tester, String label) async {
  await tapOn(tester, navItem(label));
}

Finder field(String label) => find.widgetWithText(TextField, label);

// -----------------------------------------------------------------------------
// Flows
// -----------------------------------------------------------------------------
Future<void> loginValidationAndWrongPassword(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);

  await tapOn(tester, find.widgetWithText(FilledButton, 'Sign in'));
  expect(find.text('Enter your user ID'), findsOneWidget);
  expect(find.text('Enter your password'), findsOneWidget);
  expect(api.count('POST', '/auth/login'), 0);

  await signIn(tester, 'superadmin@example.com', 'wrong');
  expect(find.text('The username or password is incorrect.'), findsOneWidget);
  expect(find.byType(NavigationRail), findsNothing);
}

Future<void> superAdminSeesPlatformOverview(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);
  await signIn(tester, 'superadmin@example.com', 'Platform@123');

  expect(find.text('Platform overview'), findsOneWidget);
  expect(find.text('Demo Society'), findsOneWidget);
  expect(navItem('Organisations'), findsOneWidget);
  expect(navItem('Members'), findsNothing);
}

Future<void> superAdminLanguagePackCrud(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);
  await signIn(tester, 'superadmin@example.com', 'Platform@123');
  await openNav(tester, 'Language packs');

  expect(find.text('தமிழ்'), findsOneWidget);
  expect(find.text('v1'), findsOneWidget);
  await tapOn(tester, find.widgetWithText(OutlinedButton, 'Create draft'));
  expect(find.text('v2'), findsOneWidget);
  expect(api.translationVersion, 2);

  await tapOn(tester, find.text('Members').last);
  final translationField = find.byType(TextField).last;
  await typeInto(tester, translationField, 'உறுப்பினர் பட்டியல்');
  await tester.tap(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tapOn(tester, find.text('Approved').last);
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save'));
  expect(api.translations['nav_members']?['translated_text'], 'உறுப்பினர் பட்டியல்');
  expect(api.translations['nav_members']?['translation_status'], 'APPROVED');
  expect(api.count('PUT', '/super-admin/language-packs/ta/2/translations/nav_members'), 1);

  expect(find.text('Publish'), findsOneWidget);
  await tapOn(tester, find.text('Publish'));
  await tapOn(tester, find.text('Publish').last);
  expect(api.translationPackStatus, 'PUBLISHED');
  expect(api.count('POST', '/super-admin/language-packs/ta/2/publish'), 1);
}

Future<void> firstLoginChangesPasswordThenShowsTenantOverview(
  WidgetTester tester,
) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);
  await signIn(tester, 'admin@demo.example.com', 'Welcome@123');

  expect(
    find.text('For your security, set a new password before continuing.'),
    findsOneWidget,
  );
  final fields = find.byType(TextFormField);
  await typeInto(tester, fields.at(0), 'Welcome@123');
  await typeInto(tester, fields.at(1), 'Welcome@12345');
  await typeInto(tester, fields.at(2), 'Different@123');
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save password'));
  expect(find.text('The passwords do not match.'), findsOneWidget);
  expect(api.count('POST', '/auth/change-initial-password'), 0);

  await typeInto(tester, fields.at(2), 'Welcome@12345');
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save password'));

  expect(
    api.users[1].mustChangePassword,
    isFalse,
    reason: [
      'requests: ${api.requests.map((r) => '${r.method} ${r.url.path} ${r.body}').join(' | ')}',
      'fields: ${tester.widgetList<EditableText>(find.byType(EditableText)).map((e) => e.controller.text).join(', ')}',
      'texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().join(' / ')}',
    ].join('; '),
  );
  expect(find.text('Organisation overview'), findsOneWidget);
  expect(find.text('Active users'), findsOneWidget);
  expect(navItem('Roles & privileges'), findsOneWidget);
  expect(navItem('Loans'), findsOneWidget);
}

Future<void> menuFollowsPrivilegesAndModules(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api, sessionCheck: const Duration(seconds: 1));
  await signIn(tester, 'emp@demo.example.com', 'Staff@12345');

  expect(navItem('Members'), findsOneWidget);
  expect(navItem('Loans'), findsNothing, reason: 'EMP has no loan.view here');
  expect(navItem('Roles & privileges'), findsNothing);

  // An administrator revokes member.view: the menu updates on the next check.
  api.rolePrivileges['EMP']!.remove('member.view');
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  expect(navItem('Members'), findsNothing);

  // Granted again, but the Super Admin disables the module: still hidden.
  api.rolePrivileges['EMP']!.add('member.view');
  api.modules['MEMBER'] = false;
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  expect(navItem('Members'), findsNothing);

  api.modules['MEMBER'] = true;
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  expect(navItem('Members'), findsOneWidget);
}

Future<void> membersListCreateDuplicateAndStaleEdit(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);
  await signIn(tester, 'emp@demo.example.com', 'Staff@12345');
  await openNav(tester, 'Members');

  // Page size 2 from organisation settings, then "Load more".
  expect(find.text('Anbu Selvan'), findsOneWidget);
  expect(find.text('Kavitha R'), findsOneWidget);
  expect(find.text('Murugan K'), findsNothing);
  await tapOn(tester, find.text('Load more'));
  expect(find.text('Murugan K'), findsOneWidget);

  // Create with a duplicate mobile: confirm with a reason.
  await tapOn(tester, find.text('New member'));
  await typeInto(tester, field('Full name'), 'Selvi Anbu');
  await typeInto(tester, field('Mobile'), '9000000001');
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save'));
  expect(find.text('Possible duplicate member'), findsOneWidget);
  await typeInto(
    tester,
    field('Why is this a different person? (3-500 characters)'),
    'Daughter, shares the family phone',
  );
  await tapOn(tester, find.widgetWithText(FilledButton, 'Confirm and save'));
  expect(api.members.last.fields['full_name'], 'Selvi Anbu');
  final creates = api.requests
      .where((r) => r.method == 'POST' && r.url.path.endsWith('/members'))
      .toList();
  expect(creates, hasLength(2));
  expect(creates.every((r) => r.headers['Idempotency-Key'] != null), isTrue);
  expect(
    creates[0].headers['Idempotency-Key'],
    isNot(creates[1].headers['Idempotency-Key']),
  );

  // Edit a member someone else changed meanwhile: reload and save again.
  await tapOn(tester, find.text('Kavitha R'));
  api.touchMember('m-2', city: 'Trichy');
  await typeInto(tester, field('City'), 'Coimbatore');
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save'));
  expect(find.text('Record changed'), findsOneWidget);
  await tapOn(tester, find.widgetWithText(FilledButton, 'Reload'));
  expect(find.widgetWithText(TextField, 'Trichy'), findsOneWidget);
  await typeInto(tester, field('City'), 'Coimbatore');
  await tapOn(tester, find.widgetWithText(FilledButton, 'Save'));
  expect(api.members[1].fields['city'], 'Coimbatore');
  final patches = api.requests.where((r) => r.method == 'PATCH').toList();
  expect(patches.map((r) => r.headers['X-Expected-Row-Version']), ['1', '2']);
}

Future<void> tamilSwitchDoesNotCrash(WidgetTester tester) async {
  final api = FakeCfmsApi();
  await pumpApp(tester, api);
  await tapOn(tester, find.text('தமிழ்'));
  expect(tester.takeException(), isNull);

  await typeInto(
    tester,
    find.byType(TextFormField).at(0),
    'emp@demo.example.com',
  );
  await typeInto(tester, find.byType(TextFormField).at(1), 'Staff@12345');
  await tapOn(tester, find.byType(FilledButton));
  expect(tester.takeException(), isNull);
  expect(find.byType(NavigationRail), findsOneWidget);
  expect(navItem('உறுப்பினர்கள்'), findsOneWidget);
  await openNav(tester, 'உறுப்பினர்கள்');
  expect(tester.takeException(), isNull);
  expect(find.text('Anbu Selvan'), findsOneWidget);
  final languageHeaders = api.requests
      .map((r) => r.headers['Accept-Language'])
      .toSet();
  expect(languageHeaders, {'ta'});
}
