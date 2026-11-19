import 'package:flutter/material.dart';

import '../../services/localization_service.dart';

class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isLoading,
    required this.onRefresh,
  });
  final String title;
  final String subtitle;
  final bool isLoading;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: AppStrings.of(context).text('refresh'),
          onPressed: isLoading ? null : onRefresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

class DashboardLoading extends StatelessWidget {
  const DashboardLoading({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 48),
    child: Center(child: CircularProgressIndicator()),
  );
}

class DashboardError extends StatelessWidget {
  const DashboardError({
    super.key,
    required this.message,
    required this.onRetry,
  });
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: Text(AppStrings.of(context).text('retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.detail,
  });
  final String label;
  final String value;
  final IconData icon;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
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
              Text(label, style: muted),
              if (detail != null)
                Text(detail!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
