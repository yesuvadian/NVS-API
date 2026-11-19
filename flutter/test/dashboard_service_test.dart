import 'dart:convert';

import 'package:cfms_portal/providers/dashboard_provider.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:cfms_portal/services/dashboard_service.dart';
import 'package:cfms_portal/ui/tenant/tenant_dashboard.dart';
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

void main() {
  test('platform summary is parsed from GET /super-admin/summary', () async {
    late http.Request seen;
    final service = DashboardService(
      config,
      client: MockClient((request) async {
        seen = request;
        return json({
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
              'id': 'b6d6d1c2-0000-0000-0000-000000000001',
              'code': 'demo',
              'name': 'Demo Society',
              'status': 'ACTIVE',
              'created_at': '2026-11-18T10:00:00Z',
            },
          ],
        });
      }),
    );

    final summary = await service.platformSummary('tok', 'ta');

    expect(
      seen.url.toString(),
      'http://localhost:8000/api/v1/super-admin/summary',
    );
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['Accept-Language'], 'ta');
    expect(summary.total, 13);
    expect(summary.count('CLOSED'), 12);
    expect(summary.count('UNKNOWN'), 0);
    expect(summary.newest.single.code, 'demo');
    expect(summary.newest.single.createdAt, DateTime.utc(2026, 11, 18, 10));
  });

  test(
    'tenant summary keeps hidden sections null and parses string amounts',
    () async {
      final service = DashboardService(
        config,
        client: MockClient(
          (request) async => json({
            'working_date': '2026-11-19',
            'sections': ['members', 'collections'],
            'members': {'total': 5, 'active': 4},
            'collections': {
              'date': '2026-11-19',
              'count': 2,
              'amount': '1500.50',
            },
          }),
        ),
      );

      final summary = await service.tenantSummary('tok', 'en');

      expect(summary.membersTotal, 5);
      expect(summary.membersActive, 4);
      expect(summary.openApplications, isNull);
      expect(summary.pendingApprovals, isNull);
      expect(summary.collectionsCount, 2);
      expect(summary.collectionsAmount, 1500.5);
      expect(summary.isEmpty, isFalse);
    },
  );

  test('API error is raised as AuthException with its short code', () async {
    final service = DashboardService(
      config,
      client: MockClient(
        (request) async => json({
          'detail': {
            'shortCode': 'NO_PRIVILEGE',
            'message': 'You do not have permission to do this.',
          },
        }, 403),
      ),
    );

    expect(
      () => service.tenantSummary('tok', 'en'),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'NO_PRIVILEGE'),
      ),
    );
  });

  test('provider reports session expiry and keeps the error message', () async {
    String? expiredCode;
    final provider = DashboardProvider<TenantSummary>(
      (token, language) async =>
          throw const AuthException('Session ended', code: 'SESSION_EXPIRED'),
      'tok',
      () => 'en',
      onSessionExpired: (message, code) => expiredCode = code,
    );

    await provider.load();

    expect(provider.isLoading, isFalse);
    expect(provider.error, 'Session ended');
    expect(expiredCode, 'SESSION_EXPIRED');
  });

  test('empty tenant summary has no sections', () async {
    final service = DashboardService(
      config,
      client: MockClient((request) async => json({'sections': []})),
    );

    final summary = await service.tenantSummary('tok', 'en');

    expect(summary.isEmpty, isTrue);
    expect(summary.activeUsers, isNull);
  });

  test('administration section is parsed', () async {
    final service = DashboardService(
      config,
      client: MockClient(
        (request) async => json({
          'working_date': '2026-11-19',
          'sections': ['administration'],
          'administration': {
            'active_users': 6,
            'locked_users': 1,
            'must_change_password': 2,
            'pending_setting_approvals': 3,
          },
        }),
      ),
    );

    final summary = await service.tenantSummary('tok', 'en');

    expect(summary.isEmpty, isFalse);
    expect(summary.membersTotal, isNull);
    expect(summary.activeUsers, 6);
    expect(summary.lockedUsers, 1);
    expect(summary.mustChangePassword, 2);
    expect(summary.pendingSettingApprovals, 3);
  });

  test('rupee amounts use Indian digit grouping', () {
    expect(formatRupees(0), '₹0.00');
    expect(formatRupees(42500), '₹42,500.00');
    expect(formatRupees(1234567.5), '₹12,34,567.50');
  });
}
