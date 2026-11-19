// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:cfms_portal/app.dart';
import 'package:cfms_portal/services/app_config_service.dart';

void main() {
  testWidgets('CFMS unified sign-in is shown', (WidgetTester tester) async {
    final config = AppConfig(
      appName: 'CFMS',
      apiBaseUrl: Uri.parse('http://localhost:8000'),
      apiPrefix: '/api/v1',
      defaultLocale: 'en',
      supportedLocales: const ['en', 'ta'],
      themeMode: 'system',
      defaultPageSize: 20,
      maxPageSize: 100,
    );
    await tester.pumpWidget(CfmsApp(config: config));
    await tester.pumpAndSettle();

    expect(find.text('CFMS'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
