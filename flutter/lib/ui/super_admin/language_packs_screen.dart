import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/translation_service.dart';

class LanguagePacksScreen extends StatefulWidget {
  const LanguagePacksScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    required this.canAdd,
    required this.canEdit,
    required this.canApprove,
    required this.pageSize,
  });
  final TranslationService service;
  final String token;
  final String Function() language;
  final bool canAdd;
  final bool canEdit;
  final bool canApprove;
  final int pageSize;
  @override
  State<LanguagePacksScreen> createState() => _LanguagePacksScreenState();
}

class _LanguagePacksScreenState extends State<LanguagePacksScreen> {
  String _targetLanguage = 'ta';
  List<Map<String, dynamic>> _packs = [];
  List<Map<String, dynamic>> _entries = [];
  int? _version;
  int _offset = 0;
  bool _loading = false;
  bool _hasMore = false;
  bool _missingOnly = false;
  String? _error;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadPacks({bool selectLatest = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final packs = await widget.service.packs(
        widget.token,
        widget.language(),
        _targetLanguage,
      );
      final selected = selectLatest
          ? (packs.isEmpty ? null : packs.first['version_no'] as int)
          : _version;
      if (mounted)
        setState(() {
          _packs = packs;
          _version = selected;
          _loading = false;
        });
      await _loadEntries(reset: true);
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

  Future<void> _loadEntries({bool reset = false}) async {
    final version = _version;
    if (version == null) {
      if (mounted) setState(() => _entries = []);
      return;
    }
    final offset = reset ? 0 : _offset;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.service.entries(
        widget.token,
        widget.language(),
        _targetLanguage,
        version,
        widget.pageSize,
        offset,
        query: _query.text,
        missingOnly: _missingOnly,
      );
      if (mounted)
        setState(() {
          _entries = reset ? rows : [..._entries, ...rows];
          _offset = offset + rows.length;
          _hasMore = rows.length == widget.pageSize;
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

  Future<void> _createDraft() async {
    try {
      await widget.service.createDraft(
        widget.token,
        widget.language(),
        _targetLanguage,
      );
      await _loadPacks();
      if (mounted)
        _message(AppStrings.of(context).text('language_draft_created'));
    } catch (error) {
      if (mounted) _message(_errorText(error));
    }
  }

  Future<void> _edit(Map<String, dynamic> entry) async {
    final text = TextEditingController(
      text: (entry['translated_text'] ?? '').toString(),
    );
    var status =
        (entry['translation_status'] ?? 'DRAFT').toString() == 'APPROVED'
        ? 'APPROVED'
        : 'DRAFT';
    final strings = AppStrings.of(context);
    final save = await showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            '${strings.text('edit_translation')} · ${entry['text_id'] ?? entry['id'] ?? ''}',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(entry['english_text']?.toString() ?? ''),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: strings.text('translated_text'),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: InputDecoration(labelText: strings.text('status')),
                items: [
                  DropdownMenuItem(
                    value: 'DRAFT',
                    child: Text(strings.text('draft')),
                  ),
                  DropdownMenuItem(
                    value: 'APPROVED',
                    child: Text(strings.text('approved')),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => status = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.text('cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (text.text.trim(), status)),
              child: Text(strings.text('save')),
            ),
          ],
        ),
      ),
    );
    if (save == null) return;
    try {
      await widget.service.updateEntry(
        widget.token,
        widget.language(),
        _targetLanguage,
        _version!,
        (entry['text_id'] ?? entry['id']).toString(),
        save.$1,
        save.$2,
      );
      await _loadEntries(reset: true);
    } catch (error) {
      if (mounted) _message(_errorText(error));
    }
  }

  Future<void> _publish() async {
    final strings = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.text('publish_language_pack')),
        content: Text(strings.text('publish_language_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('publish')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.service.publish(
        widget.token,
        widget.language(),
        _targetLanguage,
        _version!,
      );
      await _loadPacks(selectLatest: false);
    } catch (error) {
      if (mounted) _message(_errorText(error));
    }
  }

  void _message(String value) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(value)));

  String _errorText(Object error) => error is AuthException
      ? error.message
      : AppStrings.of(context).text('unexpected_error');

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    Map<String, dynamic>? selectedPack;
    for (final pack in _packs) {
      if (pack['version_no'] == _version) {
        selectedPack = pack;
        break;
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
            width: 220,
                child: DropdownButtonFormField<String>(
                  initialValue: _targetLanguage,
                  decoration: InputDecoration(
                    labelText: strings.text('target_language'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'en',
                      child: Text(strings.text('english')),
                    ),
                    DropdownMenuItem(
                      value: 'ta',
                      child: Text(strings.text('tamil')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null)
                      setState(() {
                        _targetLanguage = value;
                        _version = null;
                      });
                    _loadPacks();
                  },
                ),
              ),
              SizedBox(
            width: 230,
                child: DropdownButtonFormField<int>(
                  initialValue: _version,
                  decoration: InputDecoration(
                    labelText: strings.text('version'),
                  ),
                  items: _packs
                      .map(
                        (pack) => DropdownMenuItem(
                          value: pack['version_no'] as int,
                          child: Text('v${pack['version_no']}'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() => _version = value);
                    _loadEntries(reset: true);
                  },
                ),
              ),
              if (selectedPack != null)
                Chip(label: Text((selectedPack['status'] ?? '').toString())),
              if (widget.canAdd)
                OutlinedButton.icon(
                  onPressed: _loading ? null : _createDraft,
                  icon: const Icon(Icons.add),
                  label: Text(strings.text('new_draft')),
                ),
              if (widget.canApprove && selectedPack?['status'] == 'DRAFT')
                FilledButton.icon(
                  onPressed: _publish,
                  icon: const Icon(Icons.publish),
                  label: Text(strings.text('publish')),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: InputDecoration(
                    labelText: strings.text('search_translations'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onSubmitted: (_) => _loadEntries(reset: true),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: Text(strings.text('missing_only')),
                selected: _missingOnly,
                onSelected: (value) {
                  setState(() => _missingOnly = value);
                  _loadEntries(reset: true);
                },
              ),
              IconButton(
                onPressed: _loadPacks,
                icon: const Icon(Icons.refresh),
                tooltip: strings.text('refresh'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _loading && _entries.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
              ? Center(child: Text(strings.text('no_translation_entries')))
              : ListView.separated(
                  itemCount: _entries.length + (_hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == _entries.length)
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: OutlinedButton(
                            onPressed: _loading ? null : () => _loadEntries(),
                            child: Text(strings.text('load_more')),
                          ),
                        ),
                      );
                    final row = _entries[index];
                    final translated = (row['translated_text'] ?? '')
                        .toString();
                    return ListTile(
                      title: Text(
                        row['english_text']?.toString() ??
                            row['text_id']?.toString() ??
                            '',
                      ),
                      subtitle: Text(
                        translated.isEmpty
                            ? strings.text('translation_missing')
                            : translated,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Chip(
                        label: Text(
                          (row['translation_status'] ?? 'MISSING').toString(),
                        ),
                      ),
                      onTap:
                          widget.canEdit && selectedPack?['status'] == 'DRAFT'
                          ? () => _edit(row)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
