import 'package:flutter/material.dart';

import '../../services/localization_service.dart';

class TenantDashboard extends StatelessWidget {
  const TenantDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppStrings.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Anbu Nagar Residents Fund',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          strings.text('tenant_subtitle'),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        const Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _TenantMetric(
              labelKey: 'members',
              value: '1,284',
              icon: Icons.groups_outlined,
            ),
            _TenantMetric(
              labelKey: 'loan_applications',
              value: '18',
              icon: Icons.request_page_outlined,
            ),
            _TenantMetric(
              labelKey: 'approvals_pending',
              value: '6',
              icon: Icons.approval_outlined,
            ),
            _TenantMetric(
              labelKey: 'todays_collections',
              value: '₹42,500',
              icon: Icons.payments_outlined,
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
                Text(
                  strings.text('tasks_to_review'),
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                _TaskRow(
                  icon: Icons.assignment_outlined,
                  title: strings.text('loan_review'),
                  count: '6',
                ),
                const Divider(height: 1),
                _TaskRow(
                  icon: Icons.person_add_alt_1_outlined,
                  title: strings.text('member_registration'),
                  count: '4',
                ),
                const Divider(height: 1),
                _TaskRow(
                  icon: Icons.receipt_long_outlined,
                  title: strings.text('receipt_corrections'),
                  count: '1',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(strings.text('branding_note'))),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TenantMetric extends StatelessWidget {
  const _TenantMetric({
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

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.icon,
    required this.title,
    required this.count,
  });
  final IconData icon;
  final String title;
  final String count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      trailing: Badge(
        label: Text(count),
        child: const SizedBox(width: 10, height: 10),
      ),
    );
  }
}
