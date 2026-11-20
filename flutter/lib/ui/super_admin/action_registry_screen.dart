import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/super_admin_catalogue_service.dart';

class ActionRegistryScreen extends StatefulWidget {
  const ActionRegistryScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
  });
  final SuperAdminCatalogueService service;
  final String token;
  final String Function() language;

  @override
  State<ActionRegistryScreen> createState() => _ActionRegistryScreenState();
}

class _ActionRegistryScreenState extends State<ActionRegistryScreen> {
  int _tab = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = _tab == 0
          ? await widget.service.actions(widget.token, widget.language())
          : await widget.service.rules(widget.token, widget.language());
      if (mounted)
        setState(() {
          _rows = rows;
          _loading = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error is AuthException
              ? error.message
              : AppStrings.of(context).text('unexpected_error');
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final query = _search.text.toLowerCase();
    final filtered = _rows
        .where(
          (row) => row.values.any(
            (value) => value.toString().toLowerCase().contains(query),
          ),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: strings.text('search_catalogue'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: _load,
                tooltip: strings.text('refresh'),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(
                value: 0,
                label: Text(strings.text('workflow_actions')),
                icon: const Icon(Icons.bolt_outlined),
              ),
              ButtonSegment(
                value: 1,
                label: Text(strings.text('app_rules')),
                icon: const Icon(Icons.rule_outlined),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (value) {
              setState(() => _tab = value.first);
              _load();
            },
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _load,
                        child: Text(strings.text('retry')),
                      ),
                    ],
                  ),
                )
              : filtered.isEmpty
              ? Center(child: Text(strings.text('no_catalogue_entries')))
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final row = filtered[index];
                    final code =
                        row['code'] ??
                        row['name'] ??
                        row['rule_code'] ??
                        strings.text('catalogue_entry');
                    final subtitle = row.entries
                        .where(
                          (entry) => entry.key != 'code' && entry.value != null,
                        )
                        .map((entry) => '${entry.key}: ${entry.value}')
                        .join('  •  ');
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 5,
                      ),
                      child: ListTile(
                        leading: Icon(_tab == 0 ? Icons.bolt : Icons.rule),
                        title: Text('$code'),
                        subtitle: Text(subtitle),
                        isThreeLine: subtitle.length > 100,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
