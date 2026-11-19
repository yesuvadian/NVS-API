import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../providers/locale_provider.dart';
import '../../services/auth_service.dart';
import '../../services/app_config_service.dart';
import '../../services/user_service.dart';
import '../../services/localization_service.dart';
import '../super_admin/super_admin_dashboard.dart';
import '../tenant/tenant_dashboard.dart';
import '../auth/password_change_screen.dart';
import '../tenant/user_management_screen.dart';
import '../super_admin/organisations_screen.dart';
import '../../services/organisation_service.dart';
import '../../services/tenant_settings_service.dart';
import '../tenant/organisation_settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.auth,
    required this.session,
    required this.locale,
    required this.config,
  });
  final AuthProvider auth;
  final AuthSession session;
  final LocaleProvider locale;
  final AppConfig config;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  bool get _isSuperAdmin => widget.session.role == WorkspaceRole.superAdmin;

  bool _allowed(_NavItem item) =>
      (item.permission == null ||
          widget.session.permissions.contains(item.permission)) &&
      (item.module == null || widget.session.modules.contains(item.module));

  List<_NavItem> _items() {
    final dashboards = widget.session.modules
        .where((m) => m.startsWith('DASH_'))
        .toList();
    final dashboard = dashboards.isEmpty ? null : dashboards.first;
    final all = _isSuperAdmin
        ? const [
            _NavItem('nav_overview', Icons.space_dashboard_outlined),
            _NavItem(
              'nav_organisations',
              Icons.apartment_outlined,
              permission: 'tenants:can_view',
            ),
            _NavItem(
              'nav_languages',
              Icons.translate_outlined,
              permission: 'language_packs:can_view',
            ),
          ]
        : [
            if (dashboard != null)
              _NavItem(
                'nav_overview',
                Icons.space_dashboard_outlined,
                module: dashboard,
              ),
            _NavItem(
              'nav_members',
              Icons.groups_outlined,
              module: 'MEMBER',
              permission: 'member.view',
            ),
            _NavItem(
              'nav_loans',
              Icons.account_balance_wallet_outlined,
              module: 'LOAN',
              permission: 'loan.view',
            ),
            _NavItem(
              'nav_approvals',
              Icons.approval_outlined,
              module: 'APPROVAL',
              permission: 'approval.view',
            ),
            _NavItem(
              'nav_collections',
              Icons.payments_outlined,
              module: 'LOAN_REPAY',
              permission: 'loan_repay.create',
            ),
            _NavItem(
              'nav_reports',
              Icons.insert_chart_outlined,
              module: 'FIN_REPORT',
              permission: 'fin_report.view',
            ),
            _NavItem(
              'nav_settings',
              Icons.settings_outlined,
              module: 'ORG',
              permission: 'org.view',
            ),
            _NavItem('nav_my_settings', Icons.manage_accounts_outlined),
            _NavItem(
              'user_management',
              Icons.people_alt_outlined,
              module: 'USER_ROLE',
              permission: 'user_role.view',
            ),
          ];
    return all.where(_allowed).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = AppStrings.of(context);
    final items = _items();
    if (_selectedIndex >= items.length) _selectedIndex = 0;
    final compact = MediaQuery.sizeOf(context).width < 800;
    final selectedItem = items[_selectedIndex];
    final title = strings.text(selectedItem.key);
    final page = !_allowed(selectedItem)
        ? _AccessDenied(message: strings.text('access_denied'))
        : selectedItem.key == 'nav_my_settings'
        ? PasswordChangeScreen(auth: widget.auth, locale: widget.locale)
        : selectedItem.key == 'nav_organisations'
        ? OrganisationsScreen(
            token: widget.session.accessToken,
            locale: widget.locale,
            service: OrganisationService(widget.config),
            canCreate: widget.session.permissions.contains('tenants:can_add'),
            canEdit: widget.session.permissions.contains('tenants:can_edit'),
            onSessionExpired: (message, code) =>
                widget.auth.expireSession(message, code: code),
          )
        : selectedItem.key == 'user_management'
        ? UserManagementScreen(
            session: widget.session,
            locale: widget.locale,
            service: UserService(widget.config),
            settingsService: TenantSettingsService(widget.config),
            auth: widget.auth,
          )
        : selectedItem.key == 'nav_settings' &&
              {'ADM', 'LDR'}.contains(widget.session.roleCode)
        ? OrganisationSettingsScreen(
            session: widget.session,
            locale: widget.locale,
            auth: widget.auth,
            service: TenantSettingsService(widget.config),
          )
        : selectedItem.key == 'nav_overview'
        ? (_isSuperAdmin
              ? SuperAdminDashboard(
                  onCreateOrganisation:
                      widget.session.permissions.contains('tenants:can_add')
                      ? () {
                          final organisationsIndex = items.indexWhere(
                            (item) => item.key == 'nav_organisations',
                          );
                          if (organisationsIndex >= 0) {
                            setState(() => _selectedIndex = organisationsIndex);
                          }
                        }
                      : null,
                )
              : const TenantDashboard())
        : selectedItem.key == 'nav_languages'
        ? _ModulePlaceholder(title: title)
        : _ModulePlaceholder(title: title);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          PopupMenuButton<String>(
            tooltip: strings.text('language'),
            icon: const Icon(Icons.translate),
            onSelected: widget.locale.setLanguage,
            itemBuilder: (context) => [
              PopupMenuItem(value: 'en', child: Text(strings.text('english'))),
              PopupMenuItem(value: 'ta', child: Text(strings.text('tamil'))),
            ],
          ),
          if (!_isSuperAdmin)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Chip(
                  avatar: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(strings.text('working_day')),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          IconButton(
            tooltip: strings.text('sign_out'),
            onPressed: () =>
                widget.auth.signOut(widget.locale.locale.languageCode),
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          if (!compact)
            NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (index) =>
                  setState(() => _selectedIndex = index),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.icon),
                    label: Text(strings.text(item.key)),
                  ),
              ],
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  foregroundColor: theme.colorScheme.onPrimaryContainer,
                  child: Text(_isSuperAdmin ? 'CF' : 'AN'),
                ),
              ),
            ),
          Expanded(child: page),
        ],
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: _selectedIndex < 4 ? _selectedIndex : 4,
              onDestinationSelected: (index) {
                if (index < 4) {
                  setState(() => _selectedIndex = index);
                  return;
                }
                showModalBottomSheet<void>(
                  context: context,
                  builder: (context) => SafeArea(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (
                          var itemIndex = 4;
                          itemIndex < items.length;
                          itemIndex++
                        )
                          ListTile(
                            leading: Icon(items[itemIndex].icon),
                            title: Text(strings.text(items[itemIndex].key)),
                            onTap: () {
                              setState(() => _selectedIndex = itemIndex);
                              Navigator.pop(context);
                            },
                          ),
                      ],
                    ),
                  ),
                );
              },
              destinations: [
                for (final item in items.take(4))
                  NavigationDestination(
                    icon: Icon(item.icon),
                    label: strings.text(item.key),
                  ),
                NavigationDestination(
                  icon: const Icon(Icons.more_horiz),
                  label: strings.text('more'),
                ),
              ],
            )
          : null,
    );
  }
}

class _NavItem {
  const _NavItem(this.key, this.icon, {this.module, this.permission});
  final String key;
  final IconData icon;
  final String? module;
  final String? permission;
}

class _AccessDenied extends StatelessWidget {
  const _AccessDenied({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(child: Text(message));
}

class _ModulePlaceholder extends StatelessWidget {
  const _ModulePlaceholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.construction_outlined,
                size: 36,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(AppStrings.of(context).text('screen_ready')),
            ],
          ),
        ),
      ),
    );
  }
}
