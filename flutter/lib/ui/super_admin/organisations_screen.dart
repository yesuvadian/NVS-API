import 'dart:convert';

import 'package:flutter/material.dart';
import '../../providers/locale_provider.dart';
import '../../providers/organisation_provider.dart';
import '../../services/localization_service.dart';
import '../../services/auth_service.dart';
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
    OrganisationSetupOptions options;
    try {
      options = await widget.service.setupOptions(
        widget.token,
        widget.locale.locale.languageCode,
      );
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    }
    final code = TextEditingController(),
        name = TextEditingController(),
        legalName = TextEditingController(),
        registrationNo = TextEditingController(),
        address = TextEditingController(),
        timeZone = TextEditingController(
          text: '${options.defaults['time_zone'] ?? 'Asia/Kolkata'}',
        ),
        currency = TextEditingController(
          text: '${options.defaults['currency_code'] ?? 'INR'}',
        ),
        dataRegion = TextEditingController(
          text: '${options.defaults['data_region'] ?? 'IN'}',
        ),
        admin = TextEditingController(),
        mobile = TextEditingController(),
        email = TextEditingController();
    final settingText = <String, TextEditingController>{};
    final settingValues = <String, dynamic>{};
    final selectedModules = options.modules
        .where((item) => item.defaultEnabled)
        .map((item) => item.code)
        .toSet();
    final selectedFeatures = options.features
        .where((item) => item.defaultEnabled)
        .map((item) => item.code)
        .toSet();
    bool sandbox = options.defaults['is_sandbox'] as bool? ?? false;
    for (final setting in options.settings) {
      final value = setting.defaultValue;
      settingValues[setting.key] = value;
      if (setting.dataType != 'boolean' && setting.editableBy != 'FIXED') {
        final text = value == null
            ? ''
            : {'string', 'date'}.contains(setting.dataType)
            ? '$value'
            : const JsonEncoder.withIndent('  ').convert(value);
        settingText[setting.key] = TextEditingController(text: text);
      }
    }
    String? inputError;
    if (!mounted) {
      for (final controller in [
        code,
        name,
        legalName,
        registrationNo,
        address,
        timeZone,
        currency,
        dataRegion,
        admin,
        mobile,
        email,
        ...settingText.values,
      ]) {
        controller.dispose();
      }
      return;
    }
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        var step = 0;
        return StatefulBuilder(
          builder: (context, setState) {
            Widget field(
              TextEditingController controller,
              String label, {
              int maxLines = 1,
            }) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: controller,
                maxLines: maxLines,
                decoration: InputDecoration(labelText: label),
              ),
            );

            Widget settingsFor(List<OrganisationSetupSetting> rows) {
              final areas = rows.map((row) => row.area).toSet().toList();
              return Column(
                children: [
                  for (final area in areas)
                    ExpansionTile(
                      initiallyExpanded: true,
                      title: Text(area),
                      children: [
                        for (final item in rows.where(
                          (row) => row.area == area,
                        ))
                          if (item.editableBy == 'FIXED')
                            ListTile(
                              title: Text(item.name),
                              subtitle: Text(
                                '${s.text('fixed_setting')}: ${item.defaultValue ?? '—'}',
                              ),
                            )
                          else if (item.dataType == 'boolean')
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(item.name),
                              subtitle: Text(
                                item.description ?? item.key,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: settingValues[item.key] as bool? ?? false,
                              onChanged: (value) => setState(
                                () => settingValues[item.key] = value,
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: TextField(
                                controller: settingText[item.key],
                                maxLines:
                                    {'json', 'list'}.contains(item.dataType)
                                    ? 3
                                    : 1,
                                keyboardType:
                                    {
                                      'integer',
                                      'decimal',
                                    }.contains(item.dataType)
                                    ? const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      )
                                    : TextInputType.text,
                                decoration: InputDecoration(
                                  labelText: item.isProposed
                                      ? '${item.name} · ${s.text('proposed_setting')}'
                                      : item.name,
                                  helperText: item.description ?? item.key,
                                  helperMaxLines: 2,
                                  hintText:
                                      {'json', 'list'}.contains(item.dataType)
                                      ? s.text('json_value_hint')
                                      : null,
                                ),
                              ),
                            ),
                      ],
                    ),
                ],
              );
            }

            final securitySettings = options.settings
                .where((item) => item.area == 'Users and login')
                .toList();
            final otherSettings = options.settings
                .where(
                  (item) =>
                      item.area != 'Users and login' &&
                      !{
                        'general.time_zone',
                        'general.currency',
                      }.contains(item.key),
                )
                .toList();
            final steps = <Widget>[
              Column(
                children: [
                  field(code, s.text('org_code')),
                  field(name, s.text('org_name')),
                  field(legalName, s.text('legal_name')),
                  field(registrationNo, s.text('registration_no')),
                  field(address, s.text('org_address'), maxLines: 3),
                  Row(
                    children: [
                      Expanded(child: field(timeZone, s.text('time_zone'))),
                      const SizedBox(width: 12),
                      Expanded(child: field(currency, s.text('currency_code'))),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: field(dataRegion, s.text('data_region'))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(s.text('sandbox_organisation')),
                          value: sandbox,
                          onChanged: (value) => setState(() => sandbox = value),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Column(
                children: [
                  field(admin, s.text('admin_name')),
                  field(mobile, s.text('mobile')),
                  field(email, s.text('email')),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      s.textWith('template_defaults_note', {
                        'version': '${options.templateVersion}',
                      }),
                    ),
                  ),
                  settingsFor(securitySettings),
                ],
              ),
              Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(s.text('modules_note')),
                  ),
                  for (final module in options.modules)
                    SwitchListTile(
                      key: ValueKey('org-module-${module.code}'),
                      title: Text(module.name),
                      subtitle: Text(
                        module.isCore
                            ? '${module.code} · ${s.text('core_module')}'
                            : module.description ?? module.code,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: selectedModules.contains(module.code),
                      onChanged: module.isCore
                          ? null
                          : (value) async {
                              if (value && module.isOptionalLegal) {
                                final accepted = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    content: Text(
                                      s.text('legal_warning_confirm'),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: Text(s.text('cancel')),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: Text(s.text('enable')),
                                      ),
                                    ],
                                  ),
                                );
                                if (accepted != true) return;
                              }
                              setState(() {
                                if (value) {
                                  selectedModules.add(module.code);
                                } else {
                                  selectedModules.remove(module.code);
                                }
                              });
                            },
                    ),
                  const Divider(),
                  for (final feature in options.features)
                    SwitchListTile(
                      key: ValueKey('org-feature-${feature.code}'),
                      title: Text(feature.name),
                      subtitle: Text(
                        feature.legalWarning ??
                            feature.description ??
                            feature.code,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: selectedFeatures.contains(feature.code),
                      onChanged: (value) async {
                        if (value && feature.legalWarning != null) {
                          final accepted = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(feature.name),
                              content: Text(feature.legalWarning!),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: Text(s.text('cancel')),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: Text(s.text('enable')),
                                ),
                              ],
                            ),
                          );
                          if (accepted != true) return;
                        }
                        setState(() {
                          if (value) {
                            selectedFeatures.add(feature.code);
                          } else {
                            selectedFeatures.remove(feature.code);
                          }
                        });
                      },
                    ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    s.textWith('template_defaults_note', {
                      'version': '${options.templateVersion}',
                    }),
                  ),
                  settingsFor(otherSettings),
                ],
              ),
            ];
            final headings = [
              s.text('wizard_step_profile'),
              s.text('wizard_step_admin_security'),
              s.text('wizard_step_modules_features'),
              s.text('wizard_step_settings'),
            ];

            return AlertDialog(
              title: Text('${s.text('create_org')} · ${headings[step]}'),
              content: SizedBox(
                width: 720,
                height: 620,
                child: Column(
                  children: [
                    LinearProgressIndicator(value: (step + 1) / steps.length),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        s.textWith('wizard_step_of', {
                          'step': '${step + 1}',
                          'count': '${steps.length}',
                        }),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(child: SingleChildScrollView(child: steps[step])),
                    if (inputError != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          inputError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: step == 0
                      ? () => Navigator.pop(dialogContext)
                      : () => setState(() {
                          step--;
                          inputError = null;
                        }),
                  child: Text(step == 0 ? s.text('cancel') : s.text('back')),
                ),
                FilledButton(
                  onPressed: () {
                    if (step < steps.length - 1) {
                      setState(() => step++);
                      return;
                    }
                    try {
                      final settings = <String, dynamic>{};
                      for (final item in options.settings.where(
                        (x) => x.editableBy != 'FIXED',
                      )) {
                        if (item.key == 'general.time_zone') {
                          settings[item.key] = timeZone.text.trim();
                          continue;
                        }
                        if (item.key == 'general.currency') {
                          settings[item.key] = currency.text
                              .trim()
                              .toUpperCase();
                          continue;
                        }
                        if (item.dataType == 'boolean') {
                          settings[item.key] = settingValues[item.key] ?? false;
                          continue;
                        }
                        final text = settingText[item.key]!.text.trim();
                        if (text.isEmpty && item.defaultValue == null) {
                          settings[item.key] = null;
                        } else if ({'string', 'date'}.contains(item.dataType)) {
                          settings[item.key] = text;
                        } else {
                          final parsed = jsonDecode(text);
                          if (item.dataType == 'integer' && parsed is! int) {
                            throw const FormatException();
                          }
                          if (item.dataType == 'decimal' && parsed is! num) {
                            throw const FormatException();
                          }
                          if (item.dataType == 'list' && parsed is! List) {
                            throw const FormatException();
                          }
                          if (item.dataType == 'json' &&
                              parsed is! Map &&
                              parsed is! List) {
                            throw const FormatException();
                          }
                          settings[item.key] = parsed;
                        }
                      }
                      if (code.text.trim().length < 2 ||
                          name.text.trim().length < 2 ||
                          admin.text.trim().length < 2 ||
                          mobile.text.trim().length < 7 ||
                          email.text.trim().isEmpty) {
                        inputError = s.text('validation_org_fields');
                        setState(() {});
                        return;
                      }
                      Navigator.pop(dialogContext, {
                        'code': code.text.trim().toLowerCase(),
                        'name': name.text.trim(),
                        'legal_name': legalName.text.trim().isEmpty
                            ? null
                            : legalName.text.trim(),
                        'registration_no': registrationNo.text.trim().isEmpty
                            ? null
                            : registrationNo.text.trim(),
                        'address': address.text.trim().isEmpty
                            ? <String, dynamic>{}
                            : {'formatted': address.text.trim()},
                        'time_zone': timeZone.text.trim(),
                        'currency_code': currency.text.trim().toUpperCase(),
                        'data_region': dataRegion.text.trim().toUpperCase(),
                        'is_sandbox': sandbox,
                        'admin_name': admin.text.trim(),
                        'admin_mobile': mobile.text.trim(),
                        'admin_email': email.text.trim(),
                        'optional_modules': selectedModules
                            .where(
                              (code) => !options.modules
                                  .firstWhere((item) => item.code == code)
                                  .isCore,
                            )
                            .toList(),
                        'features': selectedFeatures.toList(),
                        'password_history_count':
                            settings['users.password_history'] ??
                            options.defaults['password_history'],
                        'single_session_enabled':
                            settings['users.single_session'] ??
                            options.defaults['single_session'],
                        'settings': settings,
                      });
                      inputError = null;
                    } on FormatException {
                      inputError = s.text('invalid_settings_json');
                      setState(() {});
                    }
                  },
                  child: Text(
                    step == steps.length - 1
                        ? s.text('create_org')
                        : s.text('next'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (!mounted) return;
    for (final controller in [
      code,
      name,
      legalName,
      registrationNo,
      address,
      timeZone,
      currency,
      dataRegion,
      admin,
      mobile,
      email,
      ...settingText.values,
    ]) {
      controller.dispose();
    }
    if (payload == null) {
      return;
    }
    final created = await _provider.create(payload);
    if (created && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s.text('org_created_notice'))));
    }
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
