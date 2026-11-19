// AppShell layout: a long menu on a short window must scroll, not overflow.

import 'package:cfms_portal/providers/auth_provider.dart';
import 'package:cfms_portal/providers/locale_provider.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:cfms_portal/services/localization_service.dart';
import 'package:cfms_portal/ui/shared/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('long admin menu scrolls in a short window', (tester) async {
    tester.view.physicalSize = const Size(1200, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeCfmsApi();
    const session = AuthSession(
      userId: 'u-adm',
      displayName: 'Demo Admin',
      role: WorkspaceRole.tenant,
      roleCode: 'ADM',
      accessToken: 'token-u-adm',
      mustChangePassword: false,
      permissions: {
        'member.view',
        'loan.view',
        'approval.view',
        'loan_repay.view',
        'fin_report.view',
        'org.view',
        'user_role.view',
      },
      modules: {
        'DASH_ADMIN',
        'MEMBER',
        'LOAN',
        'APPROVAL',
        'LOAN_REPAY',
        'FIN_REPORT',
        'ORG',
        'USER_ROLE',
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppStrings.delegate],
        home: AppShell(
          auth: AuthProvider(ApiAuthService(api.config())),
          session: session,
          locale: LocaleProvider('en'),
          config: api.config(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    final last = find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Roles & privileges'),
    );
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
