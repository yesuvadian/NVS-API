import 'package:flutter/material.dart';
import '../../providers/locale_provider.dart';
import '../../providers/organisation_provider.dart';
import '../../services/localization_service.dart';
import '../../services/organisation_service.dart';
import '../../services/access_control_service.dart';
import 'organisation_modules_screen.dart';

class OrganisationsScreen extends StatefulWidget {
  const OrganisationsScreen({
    super.key,
    required this.token,
    required this.locale,
    required this.service,
    required this.canCreate,
    required this.canEdit,
    this.moduleService,
    this.onSessionExpired,
  });
  final String token;
  final LocaleProvider locale;
  final OrganisationService service;
  final bool canCreate;
  final bool canEdit;

  /// Opens an organisation's Modules screen when set.
  final ModuleAccessService? moduleService;
  final void Function(String message, String code)? onSessionExpired;
  @override
  State<OrganisationsScreen> createState() => _OrganisationsScreenState();
}

class _OrganisationsScreenState extends State<OrganisationsScreen> {
  late final OrganisationProvider _provider = OrganisationProvider(
    widget.service,
    widget.token,
    () => widget.locale.locale.languageCode,
    widget.service.config.defaultPageSize,
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

  Future<void> _create() async {
    final s = AppStrings.of(context);
    final code = TextEditingController(),
        name = TextEditingController(),
        admin = TextEditingController(),
        mobile = TextEditingController(),
        email = TextEditingController();
    int history = 5;
    bool single = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(s.text('create_org')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: code,
                    decoration: InputDecoration(labelText: s.text('org_code')),
                  ),
                  TextField(
                    controller: name,
                    decoration: InputDecoration(labelText: s.text('org_name')),
                  ),
                  TextField(
                    controller: admin,
                    decoration: InputDecoration(
                      labelText: s.text('admin_name'),
                    ),
                  ),
                  TextField(
                    controller: mobile,
                    decoration: InputDecoration(labelText: s.text('mobile')),
                  ),
                  TextField(
                    controller: email,
                    decoration: InputDecoration(labelText: s.text('email')),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: history,
                    decoration: InputDecoration(
                      labelText: s.text('password_history_count'),
                    ),
                    items: [
                      for (var count = 1; count <= 10; count++)
                        DropdownMenuItem(value: count, child: Text('$count')),
                    ],
                    onChanged: (value) => setState(() => history = value ?? 5),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.text('single_session_enabled')),
                    value: single,
                    onChanged: (value) => setState(() => single = value),
                  ),
                  Text(
                    s.text('single_session_help'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(s.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(s.text('create_org')),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (accepted != true) {
      code.dispose();
      name.dispose();
      admin.dispose();
      mobile.dispose();
      email.dispose();
      return;
    }
    if (code.text.trim().length < 2 ||
        name.text.trim().length < 2 ||
        admin.text.trim().length < 2 ||
        mobile.text.trim().length < 7 ||
        email.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.text('validation_org_fields'))));
      code.dispose();
      name.dispose();
      admin.dispose();
      mobile.dispose();
      email.dispose();
      return;
    }
    final created = await _provider.create({
      'code': code.text.trim().toLowerCase(),
      'name': name.text.trim(),
      'admin_name': admin.text.trim(),
      'admin_mobile': mobile.text.trim(),
      'admin_email': email.text.trim(),
      'optional_modules': <String>[],
      'features': <String>[],
      'is_sandbox': false,
      'time_zone': 'Asia/Kolkata',
      'password_history_count': history,
      'single_session_enabled': single,
    });
    if (created && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.text('org_created_notice'))));
    }
    code.dispose();
    name.dispose();
    admin.dispose();
    mobile.dispose();
    email.dispose();
  }

  Future<void> _toggle(OrganisationItem org) async {
    final enabled = org.status != 'ACTIVE';
    final s = AppStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.text(enabled ? 'enable_org' : 'disable_org')),
        content: Text(
          s.text(enabled ? 'enable_org_confirm' : 'disable_org_confirm'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.text(enabled ? 'enable' : 'disable')),
          ),
        ],
      ),
    );
    if (ok == true) await _provider.setEnabled(org, enabled);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) => Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.text('organisations'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (widget.canCreate)
                    FilledButton.icon(
                      onPressed: _create,
                      icon: const Icon(Icons.add),
                      label: Text(s.text('create_org')),
                    ),
                ],
              ),
              if (_provider.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _provider.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_provider.isLoading) const LinearProgressIndicator(),
              Expanded(
                child: ListView.separated(
                  itemCount: _provider.organisations.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final org = _provider.organisations[index];
                    final active = org.status == 'ACTIVE';
                    return ListTile(
                      onTap: widget.moduleService == null
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => OrganisationModulesScreen(
                                  service: widget.moduleService!,
                                  token: widget.token,
                                  language: () =>
                                      widget.locale.locale.languageCode,
                                  tenantId: org.id,
                                  organisationName: org.name,
                                  canEdit: widget.canEdit,
                                  onSessionExpired: widget.onSessionExpired,
                                ),
                              ),
                            ),
                      leading: const CircleAvatar(child: Icon(Icons.apartment)),
                      title: Text(org.name),
                      subtitle: Text(
                        '${org.code} · ${s.text('status_${org.status.toLowerCase()}')}',
                      ),
                      trailing: widget.canEdit
                          ? OutlinedButton(
                              onPressed: () => _toggle(org),
                              child: Text(
                                s.text(active ? 'disable' : 'enable'),
                              ),
                            )
                          : null,
                    );
                  },
                ),
              ),
              if (_provider.hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    onPressed: _provider.isLoadingMore
                        ? null
                        : _provider.loadMore,
                    icon: _provider.isLoadingMore
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.expand_more),
                    label: Text(s.text('load_more')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
