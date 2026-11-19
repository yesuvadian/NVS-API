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
import '../../services/dashboard_service.dart';
import '../../services/access_control_service.dart';
import '../tenant/roles_privileges_screen.dart';
import '../tenant/members_screen.dart';
import '../../services/member_service.dart';
import '../../services/tenant_settings_service.dart';
import '../tenant/organisation_settings_screen.dart';

/// Whether the session's privileges and enabled modules allow a menu item.
bool navItemAllowed(AuthSession session, NavItem item) {
  bool reachable(String? module, String? permission) =>
      (permission == null || session.permissions.contains(permission)) &&
      (module == null || session.modules.contains(module));
  return reachable(item.module, item.permission) ||
      item.alternatives.any((alt) => reachable(alt.$1, alt.$2));
}

/// The side menu for a session: an item shows only when the user's role holds
/// its privilege and the module is enabled for the organisation.
List<NavItem> navItemsFor(AuthSession session) {
  final dashboards = session.modules
      .where((m) => m.startsWith('DASH_'))
      .toList();
  final dashboard = dashboards.isEmpty ? null : dashboards.first;
  final all = session.role == WorkspaceRole.superAdmin
      ? const [
          NavItem('nav_overview', Icons.space_dashboard_outlined),
          NavItem(
            'nav_organisations',
            Icons.apartment_outlined,
            permission: 'tenants:can_view',
          ),
          NavItem(
            'nav_languages',
            Icons.translate_outlined,
            permission: 'language_packs:can_view',
          ),
        ]
      : [
          if (dashboard != null)
            NavItem(
              'nav_overview',
              Icons.space_dashboard_outlined,
              module: dashboard,
            ),
          NavItem(
            'nav_members',
            Icons.groups_outlined,
            module: 'MEMBER',
            permission: 'member.view',
          ),
          NavItem(
            'nav_loans',
            Icons.account_balance_wallet_outlined,
            module: 'LOAN',
            permission: 'loan.view',
          ),
          NavItem(
            'nav_approvals',
            Icons.approval_outlined,
            module: 'APPROVAL',
            permission: 'approval.view',
            // Loan approvers reach the loan approval inbox (loan.approve).
            alternatives: [('LOAN', 'loan.approve')],
          ),
          NavItem(
            'nav_collections',
            Icons.payments_outlined,
            module: 'LOAN_REPAY',
            permission: 'loan_repay.view',
          ),
          NavItem(
            'nav_reports',
            Icons.insert_chart_outlined,
            module: 'FIN_REPORT',
            permission: 'fin_report.view',
            // Loan reports are management reports (mgmt_report.view).
            alternatives: [('MGMT_REPORT', 'mgmt_report.view')],
          ),
          NavItem(
            'nav_settings',
            Icons.settings_outlined,
            module: 'ORG',
            permission: 'org.view',
          ),
          NavItem('nav_my_settings', Icons.manage_accounts_outlined),
          NavItem(
            'user_management',
            Icons.people_alt_outlined,
            module: 'USER_ROLE',
            permission: 'user_role.view',
          ),
          NavItem(
            'nav_roles',
            Icons.admin_panel_settings_outlined,
            module: 'USER_ROLE',
            permission: 'user_role.view',
          ),
        ];
  return all.where((item) => navItemAllowed(session, item)).toList();
}

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

  bool _allowed(NavItem item) => navItemAllowed(widget.session, item);

  List<NavItem> _items() => navItemsFor(widget.session);

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
            moduleService: ModuleAccessService(widget.config),
            onSessionExpired: (message, code) =>
                widget.auth.expireSession(message, code: code),
          )
        : selectedItem.key == 'nav_members'
        ? MembersScreen(
            service: MemberService(widget.config),
            token: widget.session.accessToken,
            language: () => widget.locale.locale.languageCode,
            canCreate: widget.session.permissions.contains('member.create'),
            canEdit: widget.session.permissions.contains('member.edit'),
            defaultPageSize: widget.config.defaultPageSize,
            loadPageSize: () async =>
                (await TenantSettingsService(widget.config).getPageSize(
                  widget.session,
                  widget.locale.locale.languageCode,
                )).pageSize,
            onSessionExpired: (message, code) =>
                widget.auth.expireSession(message, code: code),
          )
        : selectedItem.key == 'nav_roles'
        ? RolesPrivilegesScreen(
            service: RolePrivilegeService(widget.config),
            token: widget.session.accessToken,
            language: () => widget.locale.locale.languageCode,
            onSessionExpired: (message, code) =>
                widget.auth.expireSession(message, code: code),
            onSaved: () =>
                widget.auth.verifySession(widget.locale.locale.languageCode),
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
                  service: DashboardService(widget.config),
                  token: widget.session.accessToken,
                  language: () => widget.locale.locale.languageCode,
                  onSessionExpired: (message, code) =>
                      widget.auth.expireSession(message, code: code),
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
              : TenantDashboard(
                  service: DashboardService(widget.config),
                  token: widget.session.accessToken,
                  language: () => widget.locale.locale.languageCode,
                  onSessionExpired: (message, code) =>
                      widget.auth.expireSession(message, code: code),
                ))
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
            // Scrolls when the menu is taller than the window (many modules
            // on a laptop screen) instead of overflowing.
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: NavigationRail(
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
                  ),
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

class NavItem {
  const NavItem(
    this.key,
    this.icon, {
    this.module,
    this.permission,
    this.alternatives = const [],
  });
  final String key;
  final IconData icon;
  final String? module;
  final String? permission;

  /// Other (module, permission) pairs that also show the item.
  final List<(String, String)> alternatives;
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
