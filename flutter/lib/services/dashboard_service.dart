import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

double _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

class NewestOrganisation {
  const NewestOrganisation({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    this.createdAt,
  });
  final String id;
  final String code;
  final String name;
  final String status;
  final DateTime? createdAt;

  factory NewestOrganisation.fromJson(Map<String, dynamic> json) =>
      NewestOrganisation(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        createdAt: DateTime.tryParse('${json['created_at']}'),
      );
}

class PlatformSummary {
  const PlatformSummary({
    required this.total,
    required this.byStatus,
    required this.newest,
  });
  final int total;
  final Map<String, int> byStatus;
  final List<NewestOrganisation> newest;

  int count(String status) => byStatus[status] ?? 0;

  factory PlatformSummary.fromJson(Map<String, dynamic> json) {
    final organisations =
        json['organisations'] as Map<String, dynamic>? ?? const {};
    final byStatus =
        organisations['by_status'] as Map<String, dynamic>? ?? const {};
    return PlatformSummary(
      total: _int(organisations['total']),
      byStatus: {
        for (final entry in byStatus.entries) entry.key: _int(entry.value),
      },
      newest: [
        for (final row
            in json['newest_organisations'] as List<dynamic>? ?? const [])
          NewestOrganisation.fromJson(row as Map<String, dynamic>),
      ],
    );
  }
}

/// Live tenant Overview counts. A section is null when the user may not see it.
class TenantSummary {
  const TenantSummary({
    this.workingDate,
    this.membersTotal,
    this.membersActive,
    this.openApplications,
    this.pendingApprovals,
    this.collectionsCount,
    this.collectionsAmount,
    this.activeUsers,
    this.lockedUsers,
    this.mustChangePassword,
    this.pendingSettingApprovals,
  });
  final String? workingDate;
  final int? membersTotal;
  final int? membersActive;
  final int? openApplications;
  final int? pendingApprovals;
  final int? collectionsCount;
  final double? collectionsAmount;
  final int? activeUsers;
  final int? lockedUsers;
  final int? mustChangePassword;
  final int? pendingSettingApprovals;

  bool get isEmpty =>
      membersTotal == null &&
      openApplications == null &&
      pendingApprovals == null &&
      collectionsCount == null &&
      activeUsers == null;

  factory TenantSummary.fromJson(Map<String, dynamic> json) {
    final members = json['members'] as Map<String, dynamic>?;
    final loans = json['loans'] as Map<String, dynamic>?;
    final approvals = json['approvals'] as Map<String, dynamic>?;
    final collections = json['collections'] as Map<String, dynamic>?;
    final admin = json['administration'] as Map<String, dynamic>?;
    return TenantSummary(
      workingDate: json['working_date'] as String?,
      membersTotal: members == null ? null : _int(members['total']),
      membersActive: members == null ? null : _int(members['active']),
      openApplications: loans == null ? null : _int(loans['open_applications']),
      pendingApprovals: approvals == null ? null : _int(approvals['pending']),
      collectionsCount: collections == null ? null : _int(collections['count']),
      collectionsAmount: collections == null
          ? null
          : _double(collections['amount']),
      activeUsers: admin == null ? null : _int(admin['active_users']),
      lockedUsers: admin == null ? null : _int(admin['locked_users']),
      mustChangePassword: admin == null
          ? null
          : _int(admin['must_change_password']),
      pendingSettingApprovals: admin == null
          ? null
          : _int(admin['pending_setting_approvals']),
    );
  }
}

class DashboardService {
  DashboardService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient();
  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path) =>
      config.apiBaseUrl.resolve('${config.apiPrefix}$path');

  Map<String, String> _headers(String token, String language) => {
    'Accept': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _get(
    String path,
    String token,
    String language,
  ) async {
    final response = await _client.get(
      _uri(path),
      headers: _headers(token, language),
    );
    return parseApiResponse(response, language) as Map<String, dynamic>;
  }

  Future<PlatformSummary> platformSummary(
    String token,
    String language,
  ) async => PlatformSummary.fromJson(
    await _get('/super-admin/summary', token, language),
  );

  Future<TenantSummary> tenantSummary(String token, String language) async =>
      TenantSummary.fromJson(await _get('/tenant/summary', token, language));
}
