import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/user_management_provider.dart';
import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/user_service.dart';
import '../../services/tenant_settings_service.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({
    super.key,
    required this.session,
    required this.locale,
    required this.service,
    required this.settingsService,
    required this.auth,
  });
  final AuthSession session;
  final LocaleProvider locale;
  final UserService service;
  final TenantSettingsService settingsService;
  final AuthProvider auth;

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  late final UserManagementProvider _provider = UserManagementProvider(
    widget.service,
    widget.settingsService,
    widget.session,
    () => widget.locale.locale.languageCode,
    onSessionExpired: (message, code) =>
        widget.auth.expireSession(message, code: code),
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

  Future<void> _createUser() async {
    final strings = AppStrings.of(context);
    final name = TextEditingController();
    final email = TextEditingController();
    final mobile = TextEditingController();
    String? role = _provider.roles.isEmpty ? null : _provider.roles.first.code;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(strings.text('create_user')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: strings.text('full_name'),
                  ),
                ),
                TextField(
                  controller: email,
                  decoration: InputDecoration(labelText: strings.text('email')),
                ),
                TextField(
                  controller: mobile,
                  decoration: InputDecoration(
                    labelText: strings.text('mobile'),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: InputDecoration(labelText: strings.text('role')),
                  items: [
                    for (final item in _provider.roles)
                      DropdownMenuItem(
                        value: item.code,
                        child: Text(item.name),
                      ),
                  ],
                  onChanged: (value) => setState(() => role = value),
                ),
                const SizedBox(height: 10),
                Text(
                  strings.text('default_password_notice'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.text('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.text('create_user')),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      name.dispose();
      email.dispose();
      mobile.dispose();
      return;
    }
    if (role == null ||
        name.text.trim().length < 2 ||
        (email.text.trim().isEmpty && mobile.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.text('validation_user_fields'))),
      );
      name.dispose();
      email.dispose();
      mobile.dispose();
      return;
    }
    final created = await _provider.create(
      name: name.text.trim(),
      role: role!,
      email: email.text.trim().isEmpty ? null : email.text.trim(),
      mobile: mobile.text.trim().isEmpty ? null : mobile.text.trim(),
    );
    if (created && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.text('user_created_notice'))),
      );
    }
    name.dispose();
    email.dispose();
    mobile.dispose();
  }

  Future<void> _reset(ManagedUser user) async {
    final strings = AppStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.text('reset_password')),
        content: Text(strings.text('reset_password_confirmation')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('reset_password')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (await _provider.reset(user.id) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.text('password_reset_done'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
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
                      strings.text('user_management'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _provider.roles.isEmpty ? null : _createUser,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: Text(strings.text('create_user')),
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
              const SizedBox(height: 16),
              if (_provider.isLoading) const LinearProgressIndicator(),
              Expanded(
                child: ListView.separated(
                  itemCount: _provider.users.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final user = _provider.users[index];
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline),
                      ),
                      title: Text(user.fullName),
                      subtitle: Text(
                        '${user.username ?? ''}  ·  ${user.roleCode ?? ''}',
                      ),
                      trailing: user.id == widget.session.userId
                          ? null
                          : OutlinedButton(
                              onPressed: () => _reset(user),
                              child: Text(strings.text('reset_password')),
                            ),
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
                    label: Text(strings.text('load_more')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
