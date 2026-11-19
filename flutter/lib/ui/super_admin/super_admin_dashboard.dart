import 'package:flutter/material.dart';

import '../../services/localization_service.dart';

class SuperAdminDashboard extends StatelessWidget {
  const SuperAdminDashboard({super.key, this.onCreateOrganisation});
  final VoidCallback? onCreateOrganisation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppStrings.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          strings.text('platform_overview'),
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          strings.text('platform_subtitle'),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        const Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _MetricCard(
              labelKey: 'organisations',
              value: '24',
              icon: Icons.apartment_outlined,
            ),
            _MetricCard(
              labelKey: 'active',
              value: '21',
              icon: Icons.check_circle_outline,
            ),
            _MetricCard(
              labelKey: 'pending_setup',
              value: '2',
              icon: Icons.pending_outlined,
            ),
            _MetricCard(
              labelKey: 'platform_alerts',
              value: '1',
              icon: Icons.notifications_active_outlined,
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
                        strings.text('recent_orgs'),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (onCreateOrganisation != null)
                      FilledButton.icon(
                        onPressed: onCreateOrganisation,
                        icon: const Icon(Icons.add),
                        label: Text(strings.text('create_org')),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const _OrganisationRow(
                  name: 'Anbu Nagar Residents Fund',
                  code: 'ANRF',
                  status: 'Active',
                ),
                const Divider(height: 1),
                const _OrganisationRow(
                  name: 'Kaveri Women’s Cooperative',
                  code: 'KWC',
                  status: 'Active',
                ),
                const Divider(height: 1),
                const _OrganisationRow(
                  name: 'Nila Community Trust',
                  code: 'NCT',
                  status: 'Provisioning',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.labelKey,
    required this.value,
    required this.icon,
  });
  final String labelKey;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = AppStrings.of(context).text(labelKey);
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 14),
              Text(value, style: theme.textTheme.headlineMedium),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrganisationRow extends StatelessWidget {
  const _OrganisationRow({
    required this.name,
    required this.code,
    required this.status,
  });
  final String name;
  final String code;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        child: Text(code.substring(0, 1)),
      ),
      title: Text(name),
      subtitle: Text(code),
      trailing: Chip(label: Text(status), visualDensity: VisualDensity.compact),
    );
  }
}
