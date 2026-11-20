import 'dart:convert';

import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/localization_service.dart';
import 'package:cfms_portal/services/organisation_service.dart';
import 'package:cfms_portal/services/super_admin_catalogue_service.dart';
import 'package:cfms_portal/services/translation_service.dart';
import 'package:cfms_portal/ui/super_admin/action_registry_screen.dart';
import 'package:cfms_portal/ui/super_admin/default_org_settings_screen.dart';
import 'package:cfms_portal/ui/super_admin/language_packs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AppConfig _config(http.Client client) => AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse('http://localhost:8000'),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'system',
  defaultPageSize: 15,
  maxPageSize: 200,
  httpClient: client,
);

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: const [AppStrings.delegate],
  home: Scaffold(body: child),
);

void main() {
  testWidgets('action registry displays action and rule catalogues', (
    tester,
  ) async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.path.endsWith('app-rules')
              ? [
                  {
                    'code': 'CHECK_ELIGIBILITY',
                    'description': 'Check loan eligibility',
                  },
                ]
              : [
                  {
                    'code': 'POST_FEE',
                    'event': 'AFTER_APPROVAL',
                    'entity': 'loan',
                  },
                ],
        ),
        200,
      ),
    );
    final service = SuperAdminCatalogueService(_config(client));
    await tester.pumpWidget(
      _app(
        ActionRegistryScreen(
          service: service,
          token: 'token',
          language: () => 'en',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('POST_FEE'), findsOneWidget);
    await tester.tap(find.text('Application rules'));
    await tester.pumpAndSettle();
    expect(find.text('CHECK_ELIGIBILITY'), findsOneWidget);
  });

  testWidgets('default organisation page displays published setup defaults', (
    tester,
  ) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'settings_template_version': 4,
          'defaults': {'password_history_count': 5},
          'modules': [
            {
              'code': 'LOAN',
              'name': 'Loans',
              'is_core': true,
              'is_optional_legal': false,
              'default_enabled': true,
            },
          ],
          'features': [
            {
              'code': 'SINGLE_SESSION',
              'name': 'Single session',
              'default_enabled': false,
            },
          ],
          'settings': [
            {
              'key': 'page_size',
              'area': 'UI',
              'name': 'Page size',
              'data_type': 'INTEGER',
              'editable_by': 'ORG_ADMIN',
              'default_value': 15,
            },
          ],
        }),
        200,
      ),
    );
    final service = OrganisationService(_config(client));
    await tester.pumpWidget(
      _app(
        DefaultOrgSettingsScreen(
          service: service,
          token: 'token',
          language: () => 'en',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('v4'), findsOneWidget);
    expect(find.text('Loans'), findsOneWidget);
    expect(find.textContaining('page_size: 15'), findsOneWidget);
  });

  testWidgets('language pack shows entries and supports load more', (
    tester,
  ) async {
    var entryCalls = 0;
    final requestedPaths = <String>[];
    final client = MockClient((request) async {
      requestedPaths.add(request.url.toString());
      if (request.url.path.endsWith('/language-packs/ta')) {
        return http.Response(
          jsonEncode([
            {
              'language_code': 'ta',
              'version_no': 2,
              'status': 'DRAFT',
              'approved_count': 1,
            },
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.path.contains('/translations')) {
        entryCalls++;
        return http.Response(
          jsonEncode([
            {
              'text_id': 'nav_members',
              'module_code': 'MEMBER',
              'text_type': 'LABEL',
              'english_text': 'Members',
              'translated_text': 'உறுப்பினர்கள்',
              'translation_status': 'APPROVED',
            },
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
    });
    final service = TranslationService(_config(client));
    await tester.pumpWidget(
      _app(
        LanguagePacksScreen(
          service: service,
          token: 'token',
          language: () => 'en',
          canAdd: true,
          canEdit: true,
          canApprove: true,
          pageSize: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Members'), findsOneWidget, reason: 'requests=$requestedPaths; visible=${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).whereType<String>().join(' | ')}');
    expect(find.text('உறுப்பினர்கள்'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(entryCalls, 2);
  });
}
