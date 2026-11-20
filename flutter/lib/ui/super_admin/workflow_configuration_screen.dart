import 'dart:convert';

import 'package:flutter/material.dart';

import '../../providers/locale_provider.dart';
import '../../providers/super_admin_configuration_provider.dart';
import '../../services/localization_service.dart';
import '../shared/reason_dialog.dart';

class WorkflowConfigurationScreen extends StatefulWidget {
  const WorkflowConfigurationScreen({
    super.key,
    required this.provider,
    required this.locale,
    required this.canEdit,
  });

  final SuperAdminConfigurationProvider provider;
  final LocaleProvider locale;
  final bool canEdit;

  @override
  State<WorkflowConfigurationScreen> createState() =>
      _WorkflowConfigurationScreenState();
}

class _WorkflowConfigurationScreenState
    extends State<WorkflowConfigurationScreen> {
  final _json = TextEditingController();
  String? _code;
  String _kind = 'WORKFLOW';
  String? _message;
  bool? _valid;

  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_configurationChanged);
    widget.provider.loadOrganisations();
  }

  void _configurationChanged() {
    if (!mounted) return;
    final rows = _rows;
    if (_code == null && rows.isNotEmpty) {
      _code = rows.first['code'] as String?;
      _json.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(rows.first['definition']);
    }
    final selected = rows.where((row) => row['code'] == _code).firstOrNull;
    if (selected != null && _json.text.isEmpty) {
      _json.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(selected['definition']);
    }
    setState(() {});
  }

  List<Map<String, dynamic>> get _rows =>
      ((widget.provider.configuration[_kind == 'WORKFLOW'
                      ? 'workflows'
                      : 'rule_sets']
                  as List?) ??
              const [])
          .cast<Map>()
          .map((row) => row.cast<String, dynamic>())
          .toList();

  String _label(Map? labels) {
    if (labels == null) return '';
    final language = widget.locale.locale.languageCode;
    return '${labels[language] ?? labels['en'] ?? labels.values.firstOrNull ?? ''}';
  }

  Map<String, dynamic>? _definition() {
    try {
      final parsed = jsonDecode(_json.text);
      if (parsed is Map<String, dynamic>) return parsed;
    } on FormatException catch (error) {
      _message =
          '${AppStrings.of(context).text('workflow_invalid_json')}: ${error.message}';
    }
    return null;
  }

  Future<void> _validate() async {
    final strings = AppStrings.of(context);
    final definition = _definition();
    final code = _code;
    if (definition == null || code == null) {
      setState(() => _message ??= strings.text('workflow_select_config'));
      return;
    }
    final result = await widget.provider.validate(_kind, code, definition);
    if (!mounted) return;
    setState(() {
      _valid = result?['valid'] as bool?;
      final errors = (result?['errors'] as List? ?? const []).join('\n');
      _message = result == null
          ? widget.provider.error
          : _valid == true
          ? strings.text('workflow_valid')
          : errors;
    });
  }

  Future<void> _publish() async {
    final strings = AppStrings.of(context);
    final definition = _definition();
    final code = _code;
    if (definition == null || code == null) {
      setState(() => _message ??= strings.text('workflow_select_config'));
      return;
    }
    final reason = await askReason(
      context,
      title: strings.text('workflow_publish'),
      label: strings.text('workflow_publish_reason'),
      confirmLabel: strings.text('workflow_publish'),
    );
    if (!mounted || reason == null || reason.trim().length < 3) return;
    final checked = await widget.provider.validate(_kind, code, definition);
    if (checked?['valid'] != true) {
      if (mounted) {
        setState(() {
          _valid = false;
          _message = (checked?['errors'] as List? ?? const []).join('\n');
        });
      }
      return;
    }
    final today = DateTime.now();
    final effective =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final result = await widget.provider.publish(
      _kind,
      code,
      definition,
      reason.trim(),
      effective,
    );
    if (!mounted) return;
    setState(() {
      _valid = result != null;
      _message = result == null
          ? widget.provider.error
          : strings.textWith('workflow_published', {
              'version': '${result['version_no'] ?? ''}',
            });
    });
  }

  void _selectConfig(String? value) {
    setState(() {
      _code = value;
      _valid = null;
      _message = null;
      final selected = _rows.where((row) => row['code'] == value).firstOrNull;
      _json.text = selected == null
          ? ''
          : const JsonEncoder.withIndent('  ').convert(selected['definition']);
    });
  }

  void _selectOrganisation(String? value) {
    setState(() {
      _code = null;
      _json.clear();
      _valid = null;
      _message = null;
    });
    widget.provider.selectOrganisation(
      widget.provider.organisations.where((org) => org.id == value).firstOrNull,
    );
  }

  Map<String, dynamic> get _editedDefinition => _definition() ?? const {};

  Widget _initPreview(AppStrings strings) {
    final definition = _editedDefinition;
    final start = definition['startStage'] as String?;
    final stages = (definition['stages'] as List? ?? const []).whereType<Map>();
    final init = stages.where((stage) => stage['code'] == start).firstOrNull;
    if (init == null) return const SizedBox.shrink();
    final statuses = (init['statuses'] as Map?)?.cast<String, dynamic>() ?? {};
    final statusKey = '${statuses['initial'] ?? ''}';
    final options = (statuses['stageStatuses'] as List? ?? const [])
        .whereType<Map>();
    final status = options.where((row) => row['code'] == statusKey).firstOrNull;
    final actions = (definition['transitions'] as List? ?? const [])
        .whereType<Map>()
        .where(
          (transition) =>
              transition['from'] == start && transition['label'] is Map,
        )
        .map(
          (transition) =>
              _label((transition['label'] as Map).cast<String, dynamic>()),
        )
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              strings.text('workflow_init_preview'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Chip(label: Text('$start')),
            Chip(
              label: Text(
                _label(
                  (status?['label'] as Map?)?.cast<String, dynamic>(),
                ).ifEmpty(statusKey),
              ),
            ),
            for (final action in actions)
              OutlinedButton(onPressed: null, child: Text(action)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.provider.removeListener(_configurationChanged);
    widget.provider.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final provider = widget.provider;
    final selectedOrg = provider.selectedOrganisation;
    final rows = _rows;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: DropdownButtonFormField<String>(
                  value: selectedOrg?.id,
                  decoration: InputDecoration(
                    labelText: strings.text('org_name'),
                  ),
                  items: provider.organisations
                      .map(
                        (org) => DropdownMenuItem(
                          value: org.id,
                          child: Text(
                            '${org.name} (${org.code})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: provider.isLoading ? null : _selectOrganisation,
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  value: _kind,
                  decoration: InputDecoration(
                    labelText: strings.text('workflow_kind'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'WORKFLOW',
                      child: Text(strings.text('workflow_kind_workflow')),
                    ),
                    DropdownMenuItem(
                      value: 'RULESET',
                      child: Text(strings.text('workflow_kind_rules')),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    _kind = value ?? 'WORKFLOW';
                    _code = null;
                    _json.clear();
                  }),
                ),
              ),
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String>(
                  value: rows.any((row) => row['code'] == _code) ? _code : null,
                  decoration: InputDecoration(
                    labelText: strings.text('workflow_select_config'),
                  ),
                  items: rows
                      .map(
                        (row) => DropdownMenuItem(
                          value: '${row['code']}',
                          child: Text(
                            '${row['name']} (${row['code']})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _selectConfig,
                ),
              ),
              IconButton(
                onPressed: provider.loadConfiguration,
                tooltip: strings.text('refresh'),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.isLoading) const LinearProgressIndicator(),
          if (provider.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                provider.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_kind == 'WORKFLOW') _initPreview(strings),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _json,
              expands: true,
              minLines: null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: strings.text('workflow_definition'),
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
              readOnly: !widget.canEdit,
              onChanged: (_) => setState(() {
                _valid = null;
                _message = null;
              }),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: provider.isSaving || _code == null || !widget.canEdit
                    ? null
                    : _validate,
                icon: const Icon(Icons.rule),
                label: Text(strings.text('workflow_validate')),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: provider.isSaving || _code == null || !widget.canEdit
                    ? null
                    : _publish,
                icon: const Icon(Icons.publish),
                label: Text(strings.text('workflow_publish')),
              ),
              if (provider.isSaving) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (_message != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _message!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _valid == false
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
