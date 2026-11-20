import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/organisation_service.dart';

class DefaultOrgSettingsScreen extends StatefulWidget {
  const DefaultOrgSettingsScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
  });
  final OrganisationService service;
  final String token;
  final String Function() language;
  @override
  State<DefaultOrgSettingsScreen> createState() =>
      _DefaultOrgSettingsScreenState();
}

class _DefaultOrgSettingsScreenState extends State<DefaultOrgSettingsScreen> {
  OrganisationSetupOptions? _options;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.service.setupOptions(
        widget.token,
        widget.language(),
      );
      if (mounted) setState(() => _options = value);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AuthException
              ? error.message
              : AppStrings.of(context).text('unexpected_error'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    if (_options == null && _error == null)
      return const Center(child: CircularProgressIndicator());
    if (_error != null)
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$_error'),
            FilledButton(
              onPressed: () => setState(() {
                _error = null;
                _load();
              }),
              child: Text(strings.text('retry')),
            ),
          ],
        ),
      );
    final options = _options!;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          strings.text('defaults_read_only_note'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        _Section(
          title:
              '${strings.text('template_defaults')} · v${options.templateVersion}',
          children: options.defaults.entries
              .map((entry) => _ValueTile(title: entry.key, value: entry.value))
              .toList(),
        ),
        _Section(
          title: strings.text('modules'),
          children: options.modules
              .map(
                (item) => _ValueTile(
                  title: item.name,
                  value:
                      '${item.code} · ${item.defaultEnabled ? strings.text('enabled') : strings.text('disabled')}${item.isCore ? ' · ${strings.text('core_module')}' : ''}',
                ),
              )
              .toList(),
        ),
        _Section(
          title: strings.text('features'),
          children: options.features
              .map(
                (item) => _ValueTile(
                  title: item.name,
                  value:
                      '${item.code} · ${item.defaultEnabled ? strings.text('enabled') : strings.text('disabled')}',
                ),
              )
              .toList(),
        ),
        _Section(
          title: strings.text('organisation_settings'),
          children: options.settings
              .map(
                (item) => _ValueTile(
                  title: item.name,
                  value:
                      '${item.key}: ${item.defaultValue}${item.description == null ? '' : '\n${item.description}'}',
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: ExpansionTile(
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      initiallyExpanded: true,
      children: children,
    ),
  );
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({required this.title, required this.value});
  final String title;
  final Object? value;
  @override
  Widget build(BuildContext context) =>
      ListTile(title: Text(title), subtitle: Text('$value'));
}
