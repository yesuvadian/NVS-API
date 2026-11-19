import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../providers/tenant_settings_provider.dart';
import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/tenant_settings_service.dart';

class OrganisationSettingsScreen extends StatefulWidget {
  const OrganisationSettingsScreen({
    super.key,
    required this.session,
    required this.locale,
    required this.auth,
    required this.service,
  });

  final AuthSession session;
  final LocaleProvider locale;
  final AuthProvider auth;
  final TenantSettingsService service;

  @override
  State<OrganisationSettingsScreen> createState() =>
      _OrganisationSettingsScreenState();
}

class _OrganisationSettingsScreenState
    extends State<OrganisationSettingsScreen> {
  late final TenantSettingsProvider _provider = TenantSettingsProvider(
    widget.service,
    widget.session,
    () => widget.locale.locale.languageCode,
    onSessionExpired: (message, code) =>
        widget.auth.expireSession(message, code: code),
  );
  int? _selectedPageSize;

  bool get _isAdmin => widget.session.roleCode == 'ADM';
  bool get _isLeadership => widget.session.roleCode == 'LDR';

  @override
  void initState() {
    super.initState();
    _provider.load().then((_) {
      final settings = _provider.pageSizeSettings;
      if (mounted && settings != null) {
        setState(
          () =>
              _selectedPageSize = settings.pendingPageSize ?? settings.pageSize,
        );
      }
    });
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final size = _selectedPageSize;
    if (size == null) return;
    final saved = await _provider.requestPageSize(size);
    if (!mounted || !saved) return;
    final strings = AppStrings.of(context);
    final status = _provider.pageSizeSettings?.status;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          strings.text(
            status == 'UNCHANGED'
                ? 'page_size_unchanged'
                : 'page_size_submitted',
          ),
        ),
      ),
    );
  }

  Future<void> _decide(bool approve) async {
    final decided = await _provider.decide(approve);
    if (!mounted || !decided) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppStrings.of(
            context,
          ).text(approve ? 'page_size_approved' : 'page_size_rejected'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final settings = _provider.pageSizeSettings;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              strings.text('nav_settings'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.text('page_size'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(strings.text('page_size_help')),
                    const SizedBox(height: 16),
                    if (_provider.isLoading)
                      const LinearProgressIndicator()
                    else if (settings != null) ...[
                      if (_isAdmin)
                        DropdownButtonFormField<int>(
                          initialValue: _selectedPageSize ?? settings.pageSize,
                          decoration: InputDecoration(
                            labelText: strings.text('page_size'),
                          ),
                          items: [
                            for (var size = 5; size <= 100; size += 5)
                              DropdownMenuItem(
                                value: size,
                                child: Text('$size'),
                              ),
                          ],
                          onChanged: _provider.isSaving
                              ? null
                              : (value) =>
                                    setState(() => _selectedPageSize = value),
                        )
                      else
                        Text(
                          '${strings.text('page_size')}: ${settings.pageSize}',
                        ),
                      if (settings.pendingPageSize != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          '${strings.text('page_size_pending')} ${settings.pendingPageSize}',
                        ),
                      ],
                      if (_isAdmin) ...[
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _provider.isSaving ? null : _save,
                          child: Text(strings.text('save')),
                        ),
                      ],
                      if (_isLeadership &&
                          settings.pendingSettingId != null) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: _provider.isSaving
                                  ? null
                                  : () => _decide(true),
                              child: Text(strings.text('approve')),
                            ),
                            OutlinedButton(
                              onPressed: _provider.isSaving
                                  ? null
                                  : () => _decide(false),
                              child: Text(strings.text('reject')),
                            ),
                          ],
                        ),
                      ],
                    ],
                    if (_provider.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _provider.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
