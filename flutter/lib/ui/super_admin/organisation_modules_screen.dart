import 'package:flutter/material.dart';

import '../../services/access_control_service.dart';
import '../../services/auth_service.dart';
import '../../services/localization_service.dart';

/// Super Admin: switch an organisation's modules on and off.
class OrganisationModulesScreen extends StatefulWidget {
  const OrganisationModulesScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    required this.tenantId,
    required this.organisationName,
    required this.canEdit,
    this.onSessionExpired,
  });
  final ModuleAccessService service;
  final String token;
  final String Function() language;
  final String tenantId;
  final String organisationName;
  final bool canEdit;
  final void Function(String message, String code)? onSessionExpired;

  @override
  State<OrganisationModulesScreen> createState() =>
      _OrganisationModulesScreenState();
}

class _OrganisationModulesScreenState extends State<OrganisationModulesScreen> {
  List<TenantModule> _modules = [];
  bool _loading = true;
  String? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _handle(AuthException e) {
    setState(() => _error = e.message);
    if ({'SESSION_EXPIRED', 'NOT_SIGNED_IN'}.contains(e.code)) {
      widget.onSessionExpired?.call(e.message, e.code!);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final modules = await widget.service.list(
        widget.token,
        widget.language(),
        widget.tenantId,
      );
      setState(() => _modules = modules);
    } on AuthException catch (e) {
      _handle(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _askReason(String title) async {
    final strings = AppStrings.of(context);
    final controller = TextEditingController();
    String? problem;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: strings.text('reason'),
              errorText: problem,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.text('cancel')),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.length < 3) {
                  setDialogState(
                    () => problem = strings.text('reason_required'),
                  );
                  return;
                }
                Navigator.pop(context, text);
              },
              child: Text(strings.text('save')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _toggle(TenantModule module, bool enabled) async {
    final strings = AppStrings.of(context);
    final reason = await _askReason(
      '${strings.text(enabled ? 'enable' : 'disable')}: ${module.name}',
    );
    if (reason == null || !mounted) return;
    var legalAck = false;
    if (enabled && module.isOptionalLegal) {
      legalAck =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              content: Text(strings.text('legal_warning_confirm')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(strings.text('cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(strings.text('enable')),
                ),
              ],
            ),
          ) ??
          false;
      if (!legalAck) return;
    }
    setState(() => _busy = module.code);
    try {
      final updated = await widget.service.setEnabled(
        widget.token,
        widget.language(),
        widget.tenantId,
        module,
        enabled: enabled,
        reason: reason,
        legalWarningAck: legalAck,
      );
      setState(() {
        _modules = [
          for (final m in _modules) m.code == updated.code ? updated : m,
        ];
        _error = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.text('module_change_saved'))),
        );
      }
    } on AuthException catch (e) {
      _handle(e);
      if (e.code == 'STALE_RECORD') await _load();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${strings.text('modules')} · ${widget.organisationName}'),
        actions: [
          IconButton(
            tooltip: strings.text('refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              backgroundColor: theme.colorScheme.errorContainer,
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: Text(strings.text('cancel')),
                ),
              ],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              strings.text('modules_note'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _modules.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final module = _modules[index];
                final locked = module.isCore && module.isEnabled;
                return SwitchListTile(
                  title: Text(module.name),
                  subtitle: Text(
                    locked
                        ? '${module.code} · ${strings.text('core_module')}'
                        : module.code,
                  ),
                  value: module.isEnabled,
                  onChanged: !widget.canEdit || locked || _busy != null
                      ? null
                      : (value) => _toggle(module, value),
                  secondary: _busy == module.code
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          module.isEnabled
                              ? Icons.check_circle_outline
                              : Icons.block_outlined,
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
