import 'dart:convert';

import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/localization_service.dart';
import 'package:cfms_portal/services/member_service.dart';
import 'package:cfms_portal/ui/tenant/members_screen.dart';
import 'package:flutter/material.dart';
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

MemberService service() => MemberService(
  config,
  client: MockClient(
    (_) async => http.Response(
      jsonEncode({
        'items': [
          {
            'id': 'm1',
            'member_no': 'MEM-0001',
            'full_name': 'Kavitha R',
            'mobile': '9876543210',
            'status': 'ACTIVE',
            'row_version': 1,
          },
        ],
        'has_more': true,
        'next_offset': 1,
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  ),
);

Widget app(Widget child) => MaterialApp(
  localizationsDelegates: const [AppStrings.delegate],
  home: Scaffold(body: child),
);

void main() {
  testWidgets('lists members with Load more; create needs member.create', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        MembersScreen(
          service: service(),
          token: 'tok',
          language: () => 'en',
          canCreate: false,
          canEdit: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Kavitha R'), findsOneWidget);
    expect(find.text('Load more'), findsOneWidget);
    expect(find.text('New member'), findsNothing);

    await tester.pumpWidget(
      app(
        MembersScreen(
          service: service(),
          token: 'tok',
          language: () => 'en',
          canCreate: true,
          canEdit: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New member'), findsOneWidget);
  });
}
