import 'package:flutter/material.dart';

import '../../providers/dashboard_provider.dart';
import '../../services/dashboard_service.dart';
import '../../services/localization_service.dart';
import '../shared/dashboard_widgets.dart';

/// Formats an amount in Indian digit grouping, e.g. 1234567.5 -> ₹12,34,567.50.
String formatRupees(double amount) {
  final fixed = amount.abs().toStringAsFixed(2);
  final whole = fixed.substring(0, fixed.length - 3);
  final paise = fixed.substring(fixed.length - 2);
  var grouped = whole;
  if (whole.length > 3) {
    final head = whole.substring(0, whole.length - 3);
    final tail = whole.substring(whole.length - 3);
    final parts = <String>[];
    for (var end = head.length; end > 0; end -= 2) {
      parts.insert(0, head.substring(end - 2 < 0 ? 0 : end - 2, end));
    }
    grouped = '${parts.join(',')},$tail';
  }
  return '${amount < 0 ? '-' : ''}₹$grouped.$paise';
}

class TenantDashboard extends StatefulWidget {
  const TenantDashboard({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    this.onSessionExpired,
  });
  final DashboardService service;
  final String token;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;

  @override
  State<TenantDashboard> createState() => _TenantDashboardState();
}

class _TenantDashboardState extends State<TenantDashboard> {
  late final DashboardProvider<TenantSummary> _provider = DashboardProvider(
    widget.service.tenantSummary,
    widget.token,
    widget.language,
    onSessionExpired: widget.onSessionExpired,
  );

  @override
  void initState() {
    super.initState();
    _provider.load();
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppStrings.of(context);
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final summary = _provider.data;
        return RefreshIndicator(
          onRefresh: _provider.load,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              DashboardHeader(
                title: strings.text('tenant_overview'),
                subtitle: strings.text('tenant_subtitle'),
                isLoading: _provider.isLoading,
                onRefresh: _provider.load,
              ),
              const SizedBox(height: 22),
              if (_provider.error != null)
                DashboardError(
                  message: _provider.error!,
                  onRetry: _provider.load,
                ),
              if (summary == null && _provider.isLoading)
                const DashboardLoading(),
              if (summary != null && summary.isEmpty)
                Text(strings.text('no_dashboard_data')),
              if (summary != null && !summary.isEmpty)
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    if (summary.membersTotal != null)
                      MetricCard(
                        label: strings.text('members'),
                        value: '${summary.membersTotal}',
                        icon: Icons.groups_outlined,
                        detail: strings
                            .text('active_count')
                            .replaceAll('{n}', '${summary.membersActive ?? 0}'),
                      ),
                    if (summary.openApplications != null)
                      MetricCard(
                        label: strings.text('loan_applications'),
                        value: '${summary.openApplications}',
                        icon: Icons.request_page_outlined,
                      ),
                    if (summary.pendingApprovals != null)
                      MetricCard(
                        label: strings.text('approvals_pending'),
                        value: '${summary.pendingApprovals}',
                        icon: Icons.approval_outlined,
                      ),
                    if (summary.collectionsCount != null)
                      MetricCard(
                        label: strings.text('todays_collections'),
                        value: formatRupees(summary.collectionsAmount ?? 0),
                        icon: Icons.payments_outlined,
                        detail: strings
                            .text('receipts_count')
                            .replaceAll('{n}', '${summary.collectionsCount}'),
                      ),
                  ],
                ),
              const SizedBox(height: 18),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(strings.text('branding_note'))),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
