import 'dart:convert';

import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/localization_service.dart';
import 'package:cfms_portal/services/organisation_service.dart';
import 'package:cfms_portal/providers/locale_provider.dart';
import 'package:cfms_portal/ui/super_admin/organisations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse('http://localhost:8000'),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'light',
  defaultPageSize: 15,
  maxPageSize: 100,
);

Map<String, dynamic> _options() => {
  'settings_template_version': 7,
  'defaults': {
    'time_zone': 'Asia/Kolkata',
    'currency_code': 'INR',
    'data_region': 'IN',
    'is_sandbox': false,
    'password_history': 5,
    'single_session': false,
    'page_size': 15,
  },
  'modules': [
    {
      'code': 'MEMBER',
      'name': 'Members',
      'is_core': true,
      'is_optional_legal': false,
      'default_enabled': true,
    },
    {
      'code': 'LOAN',
      'name': 'Loans',
      'is_core': false,
      'is_optional_legal': false,
      'default_enabled': false,
    },
  ],
  'features': <Object>[],
  'settings': [
    {
      'key': 'general.time_zone',
      'area': 'General',
      'name': 'Time zone',
      'data_type': 'string',
      'editable_by': 'ORG_ADMIN',
      'default_value': 'Asia/Kolkata',
    },
    {
      'key': 'general.currency',
      'area': 'General',
      'name': 'Currency',
      'data_type': 'string',
      'editable_by': 'ORG_ADMIN',
      'default_value': 'INR',
    },
    {
      'key': 'users.password_history',
      'area': 'Users and login',
      'name': 'Password history',
      'data_type': 'integer',
      'editable_by': 'SUPER_ADMIN',
      'default_value': 5,
    },
    {
      'key': 'users.single_session',
      'area': 'Users and login',
      'name': 'Single session',
      'data_type': 'boolean',
      'editable_by': 'SUPER_ADMIN',
      'default_value': false,
    },
    {
      'key': 'ui.page_size',
      'area': 'User interface',
      'name': 'Rows per page',
      'data_type': 'integer',
      'editable_by': 'ORG_ADMIN',
      'default_value': 15,
    },
  ],
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'setup options service parses the published defaults and catalog',
    () async {
      late http.Request seen;
      final service = OrganisationService(
        _config,
        client: MockClient((request) async {
          seen = request;
          return _json(_options());
        }),
      );

      final options = await service.setupOptions('token', 'ta');

      expect(seen.url.path, '/api/v1/super-admin/organisations/setup-options');
      expect(seen.headers['authorization'], 'Bearer token');
      expect(seen.headers['accept-language'], 'ta');
      expect(options.templateVersion, 7);
      expect(options.defaults['page_size'], 15);
      expect(
        options.modules.singleWhere((row) => row.isCore).defaultEnabled,
        isTrue,
      );
      expect(
        options.settings
            .singleWhere((row) => row.key == 'ui.page_size')
            .defaultValue,
        15,
      );
    },
  );

  testWidgets('wizard steps through profile, security, modules, and defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, dynamic>? submitted;
    var listCalls = 0;
    final service = OrganisationService(
      _config,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/setup-options')) {
          return _json(_options());
        }
        if (request.url.path.endsWith('/super-admin/organisations') &&
            request.method == 'POST') {
          submitted = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({'id': 'tenant-id'});
        }
        if (request.url.path.endsWith('/super-admin/organisations') &&
            request.method == 'GET') {
          listCalls++;
          return _json(<Object>[]);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url}',
        );
      }),
    );
    final locale = LocaleProvider('en');
    addTearDown(locale.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('ta')],
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: OrganisationsScreen(
          token: 'token',
          locale: locale,
          service: service,
          canCreate: true,
          canEdit: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(listCalls, 1);

    await tester.tap(find.text('Create organisation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Organisation profile'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);

    final profileFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(profileFields.at(0), 'wizard-test');
    await tester.enterText(profileFields.at(1), 'Wizard Test Organisation');
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Admin and security'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '5',
      ),
      findsOneWidget,
    );
    final adminFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(adminFields.at(0), 'Wizard Admin');
    await tester.enterText(adminFields.at(1), '9876543210');
    await tester.enterText(adminFields.at(2), 'wizard@example.test');
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Modules and features'), findsOneWidget);
    expect(find.byKey(const ValueKey('org-module-MEMBER')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Organisation settings'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '15',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create organisation'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!['time_zone'], 'Asia/Kolkata');
    expect(submitted!['currency_code'], 'INR');
    expect(submitted!['optional_modules'], isEmpty);
    expect(submitted!['settings']['users.password_history'], 5);
    expect(submitted!['settings']['users.single_session'], isFalse);
    expect(submitted!['settings']['ui.page_size'], 15);
    expect(listCalls, 2);
  });
}
