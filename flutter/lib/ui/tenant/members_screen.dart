import 'dart:async';

import 'package:flutter/material.dart';

import '../../providers/member_provider.dart';
import '../../services/auth_service.dart';
import '../../services/localization_service.dart';
import '../../services/member_service.dart';
import 'member_form_dialog.dart';

const memberStatuses = [
  'APPLIED',
  'ACTIVE',
  'INACTIVE',
  'SUSPENDED',
  'EXITED',
  'DECEASED',
];

/// Member register: search, status filter, "Load more", create and edit.
class MembersScreen extends StatefulWidget {
  const MembersScreen({
    super.key,
    required this.service,
    required this.token,
    required this.language,
    required this.canCreate,
    required this.canEdit,
    this.loadPageSize,
    this.defaultPageSize = 15,
    this.onSessionExpired,
  });
  final MemberService service;
  final String token;
  final String Function() language;
  final bool canCreate;
  final bool canEdit;
  final Future<int> Function()? loadPageSize;
  final int defaultPageSize;
  final void Function(String message, String code)? onSessionExpired;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  late final MemberListProvider _list = MemberListProvider(
    widget.service,
    widget.token,
    widget.language,
    loadPageSize: widget.loadPageSize,
    defaultPageSize: widget.defaultPageSize,
    onSessionExpired: widget.onSessionExpired,
  );
  final _search = TextEditingController();
  Timer? _debounce;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _list.load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _list.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _list.search(value),
    );
  }

  MemberFormController _controller({Member? existing}) => MemberFormController(
    widget.service,
    widget.token,
    widget.language,
    existing: existing,
    onSessionExpired: widget.onSessionExpired,
  );

  Future<void> _create() async {
    final result = await showDialog<MemberFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MemberFormDialog(controller: _controller()),
    );
    await _afterForm(result);
  }

  Future<void> _edit(String memberId) async {
    if (_opening) return;
    setState(() => _opening = true);
    Member member;
    try {
      member = await widget.service.get(
        widget.token,
        widget.language(),
        memberId,
      );
    } on AuthException catch (e) {
      if ({'SESSION_EXPIRED', 'NOT_SIGNED_IN'}.contains(e.code)) {
        widget.onSessionExpired?.call(e.message, e.code!);
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    } finally {
      // Stop the progress bar before the form opens.
      if (mounted) setState(() => _opening = false);
    }
    if (!mounted) return;
    final result = await showDialog<MemberFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          MemberFormDialog(controller: _controller(existing: member)),
    );
    await _afterForm(result);
  }

  Future<void> _afterForm(MemberFormResult? result) async {
    if (!mounted) return;
    switch (result) {
      case MemberSaved():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.of(context).text('member_saved'))),
        );
        await _list.load();
      case MemberReloadRequested(:final memberId):
        await _list.load();
        await _edit(memberId);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _list,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    strings.text('nav_members'),
                    style: theme.textTheme.headlineMedium,
                  ),
                ),
                if (widget.canCreate)
                  FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: Text(strings.text('new_member')),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearch,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      labelText: strings.text('search_members'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _list.status,
                    decoration: InputDecoration(
                      labelText: strings.text('status'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(strings.text('all_statuses')),
                      ),
                      for (final s in memberStatuses)
                        DropdownMenuItem(
                          value: s,
                          child: Text(strings.text('status_$s')),
                        ),
                    ],
                    onChanged: _list.filterStatus,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_list.isLoading || _opening) const LinearProgressIndicator(),
            if (_list.error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_list.error!),
                  trailing: TextButton(
                    onPressed: _list.load,
                    child: Text(strings.text('retry')),
                  ),
                ),
              ),
            Expanded(
              child:
                  !_list.isLoading &&
                      _list.members.isEmpty &&
                      _list.error == null
                  ? Center(child: Text(strings.text('no_members')))
                  : ListView.separated(
                      itemCount: _list.members.length + (_list.hasMore ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index == _list.members.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: OutlinedButton.icon(
                                onPressed: _list.isLoadingMore
                                    ? null
                                    : _list.loadMore,
                                icon: _list.isLoadingMore
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.expand_more),
                                label: Text(strings.text('load_more')),
                              ),
                            ),
                          );
                        }
                        final member = _list.members[index];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              member.fullName.isEmpty
                                  ? '?'
                                  : member.fullName[0].toUpperCase(),
                            ),
                          ),
                          title: Text(member.fullName),
                          subtitle: Text(
                            [member.memberNo, member.mobile, member.city]
                                .whereType<String>()
                                .where((v) => v.isNotEmpty)
                                .join(' · '),
                          ),
                          trailing: Chip(
                            label: Text(
                              strings.text('status_${member.status}'),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          onTap: widget.canEdit ? () => _edit(member.id) : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
