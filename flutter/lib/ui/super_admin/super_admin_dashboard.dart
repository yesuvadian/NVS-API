import 'package:flutter/material.dart';

import '../../providers/dashboard_provider.dart';
import '../../services/dashboard_service.dart';
import '../../services/localization_service.dart';
import '../shared/dashboard_widgets.dart';

class SuperAdminDashboard extends StatefulWidget {
  const SuperAdminDashboard({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    this.onSessionExpired,
    this.onCreateOrganisation,
  });
  final DashboardService service;
  final String token;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;
  final VoidCallback? onCreateOrganisation;

  @override
  State<SuperAdminDashboard> createState() => _SuperAdminDashboardState();
}

class _SuperAdminDashboardState extends State<SuperAdminDashboard> {
  late final DashboardProvider<PlatformSummary> _provider = DashboardProvider(
    widget.service.platformSummary,
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
                title: strings.text('platform_overview'),
                subtitle: strings.text('platform_subtitle'),
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
              if (summary != null) ...[
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    MetricCard(
                      label: strings.text('organisations'),
                      value: '${summary.total}',
                      icon: Icons.apartment_outlined,
                    ),
                    MetricCard(
                      label: strings.text('active'),
                      value: '${summary.count('ACTIVE')}',
                      icon: Icons.check_circle_outline,
                    ),
                    MetricCard(
                      label: strings.text('pending_setup'),
                      value: '${summary.count('PROVISIONING')}',
                      icon: Icons.pending_outlined,
                    ),
                    MetricCard(
                      label: strings.text('suspended'),
                      value: '${summary.count('SUSPENDED')}',
                      icon: Icons.pause_circle_outline,
                    ),
                    MetricCard(
                      label: strings.text('closed'),
                      value: '${summary.count('CLOSED')}',
                      icon: Icons.block_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                strings.text('newest_orgs'),
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                            if (widget.onCreateOrganisation != null)
                              FilledButton.icon(
                                onPressed: widget.onCreateOrganisation,
                                icon: const Icon(Icons.add),
                                label: Text(strings.text('create_org')),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (summary.newest.isEmpty)
                          Text(strings.text('no_orgs_yet')),
                        for (final (index, org) in summary.newest.indexed) ...[
                          if (index > 0) const Divider(height: 1),
                          _OrganisationRow(organisation: org),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _OrganisationRow extends StatelessWidget {
  const _OrganisationRow({required this.organisation});
  final NewestOrganisation organisation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppStrings.of(context);
    final code = organisation.code;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        child: Text(code.isEmpty ? '?' : code.substring(0, 1).toUpperCase()),
      ),
      title: Text(organisation.name),
      subtitle: Text(code),
      trailing: Chip(
        label: Text(strings.text('status_${organisation.status}')),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
