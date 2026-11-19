import 'package:flutter/material.dart';

import '../../services/access_control_service.dart';
import '../../services/auth_service.dart';
import '../../services/localization_service.dart';

/// Action columns in display order (privilege type codes).
const privilegeTypeOrder = ['V', 'C', 'E', 'A', 'D', 'X', 'H', 'U'];

/// Organisation admin: pick a role, tick module x action privileges, save.
/// Changes apply immediately.
class RolesPrivilegesScreen extends StatefulWidget {
  const RolesPrivilegesScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    this.onSessionExpired,
    this.onSaved,
  });
  final RolePrivilegeService service;
  final String token;
  final String Function() language;
  final void Function(String message, String code)? onSessionExpired;

  /// Called after changes were saved (refreshes the signed-in user's menu).
  final VoidCallback? onSaved;

  @override
  State<RolesPrivilegesScreen> createState() => _RolesPrivilegesScreenState();
}

class _RolesPrivilegesScreenState extends State<RolesPrivilegesScreen> {
  RolePrivilegeMatrix? _matrix;
  String? _roleId;
  final Map<String, bool> _pending = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  MatrixRole? get _role {
    final matrix = _matrix;
    if (matrix == null || matrix.roles.isEmpty) return null;
    return matrix.roles.firstWhere(
      (r) => r.id == _roleId,
      orElse: () => matrix.roles.first,
    );
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
      final matrix = await widget.service.matrix(
        widget.token,
        widget.language(),
      );
      setState(() {
        _matrix = matrix;
        _pending.clear();
        if (!matrix.roles.any((r) => r.id == _roleId)) {
          _roleId = matrix.roles.isEmpty ? null : matrix.roles.first.id;
        }
      });
    } on AuthException catch (e) {
      _handle(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isChecked(MatrixRole role, PrivilegeAction action) =>
      _pending[action.code] ?? role.privileges.contains(action.code);

  void _toggle(MatrixRole role, PrivilegeAction action, bool value) {
    setState(() {
      if (value == role.privileges.contains(action.code)) {
        _pending.remove(action.code);
      } else {
        _pending[action.code] = value;
      }
    });
  }

  Future<void> _save() async {
    final role = _role;
    if (role == null || _pending.isEmpty) return;
    final strings = AppStrings.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    var saved = 0;
    try {
      for (final entry in Map.of(_pending).entries) {
        await widget.service.setPrivilege(
          widget.token,
          widget.language(),
          role.id,
          entry.key,
          granted: entry.value,
        );
        saved++;
        _pending.remove(entry.key);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              strings.text('changes_saved').replaceAll('{n}', '$saved'),
            ),
          ),
        );
      }
    } on AuthException catch (e) {
      _handle(e);
    } finally {
      if (mounted) setState(() => _saving = false);
      if (saved > 0) {
        widget.onSaved?.call();
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final theme = Theme.of(context);
    final matrix = _matrix;
    final role = _role;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.text('nav_roles'),
                style: theme.textTheme.headlineMedium,
              ),
            ),
            IconButton(
              tooltip: strings.text('refresh'),
              onPressed: _loading || _saving ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          strings.text('privileges_note'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Card(
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(_error!),
            ),
          ),
        if (matrix != null && role != null) ...[
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: DropdownButtonFormField<String>(
                  initialValue: role.id,
                  decoration: InputDecoration(
                    labelText: strings.text('select_role'),
                  ),
                  items: [
                    for (final r in matrix.roles)
                      DropdownMenuItem(
                        value: r.id,
                        child: Text('${r.name} (${r.code})'),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                          _roleId = value;
                          _pending.clear();
                        }),
                ),
              ),
              if (matrix.canEdit)
                FilledButton.icon(
                  onPressed: _pending.isEmpty || _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    '${strings.text('save_changes')}'
                    '${_pending.isEmpty ? '' : ' (${_pending.length})'}',
                  ),
                ),
              if (role.isReadOnly) Chip(label: Text(strings.text('read_only'))),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(strings.text('module'))),
                  for (final type in privilegeTypeOrder)
                    DataColumn(label: Text(strings.text('action_$type'))),
                ],
                rows: [
                  for (final module in matrix.modules)
                    DataRow(
                      cells: [
                        DataCell(Text(module.name)),
                        for (final type in privilegeTypeOrder)
                          DataCell(_cell(matrix, role, module, type, strings)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _cell(
    RolePrivilegeMatrix matrix,
    MatrixRole role,
    MatrixModule module,
    String type,
    AppStrings strings,
  ) {
    final action = module.actions.where((a) => a.typeCode == type).firstOrNull;
    if (action == null) return const SizedBox.shrink();
    final enabled = !_saving && canChangePrivilege(matrix, role, action);
    final box = Checkbox(
      value: _isChecked(role, action),
      onChanged: enabled ? (v) => _toggle(role, action, v ?? false) : null,
    );
    if (action.protected) {
      return Tooltip(message: strings.text('protected_privilege'), child: box);
    }
    return Tooltip(message: action.code, child: box);
  }
}
