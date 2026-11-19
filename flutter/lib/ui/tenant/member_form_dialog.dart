import 'package:flutter/material.dart';

import '../../providers/member_provider.dart';
import '../../services/localization_service.dart';
import '../../services/member_service.dart';

/// What the form dialog returns.
sealed class MemberFormResult {
  const MemberFormResult();
}

class MemberSaved extends MemberFormResult {
  const MemberSaved(this.member);
  final Member member;
}

/// The record changed elsewhere; the caller re-fetches and opens it again.
class MemberReloadRequested extends MemberFormResult {
  const MemberReloadRequested(this.memberId);
  final String memberId;
}

const _genders = ['MALE', 'FEMALE', 'OTHER', 'UNDISCLOSED'];
const _channels = ['SMS', 'WHATSAPP', 'EMAIL', 'NONE'];
const _textFields = [
  'full_name',
  'mobile',
  'alt_mobile',
  'email',
  'date_of_birth',
  'address_line1',
  'address_line2',
  'city',
  'district',
  'state',
  'pincode',
];

/// Create or edit one member. The [controller] carries the Idempotency-Key
/// (create) or the opened row_version (edit) for every submission.
class MemberFormDialog extends StatefulWidget {
  const MemberFormDialog({super.key, required this.controller});
  final MemberFormController controller;

  @override
  State<MemberFormDialog> createState() => _MemberFormDialogState();
}

class _MemberFormDialogState extends State<MemberFormDialog> {
  late final Map<String, TextEditingController> _text = {
    for (final field in _textFields)
      field: TextEditingController(
        text: '${widget.controller.existing?.values[field] ?? ''}',
      ),
  };
  late String? _gender =
      widget.controller.existing?.values['gender'] as String?;
  late String _channel =
      widget.controller.existing?.values['preferred_channel'] as String? ??
      'SMS';
  Map<String, String> _fieldErrors = {};
  String? _message;
  bool _saving = false;

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _fields() => {
    for (final entry in _text.entries) entry.key: entry.value.text,
    'gender': _gender,
    'preferred_channel': _channel,
  };

  Future<void> _submit({String? duplicateReason}) async {
    final strings = AppStrings.of(context);
    final fields = _fields();
    final problems = validateMemberFields(fields);
    if (problems.isNotEmpty) {
      setState(() {
        _fieldErrors = {
          for (final entry in problems.entries)
            entry.key: strings.text(entry.value),
        };
        _message = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
      _fieldErrors = {};
    });
    final result = await widget.controller.submit(
      fields,
      duplicateReason: duplicateReason,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result.outcome) {
      case MemberSubmitOutcome.saved:
        Navigator.of(context).pop(MemberSaved(result.member!));
      case MemberSubmitOutcome.noChanges:
        setState(() => _message = strings.text('no_changes'));
      case MemberSubmitOutcome.duplicate:
        final reason = await _askDuplicateReason(result.message ?? '');
        if (reason != null && mounted) await _submit(duplicateReason: reason);
      case MemberSubmitOutcome.stale:
        await _offerReload(result.message ?? '');
      case MemberSubmitOutcome.invalid:
        setState(() {
          _fieldErrors = result.fieldErrors;
          _message = result.message;
        });
      case MemberSubmitOutcome.failed:
        setState(() => _message = result.message);
    }
  }

  Future<String?> _askDuplicateReason(String message) async {
    final strings = AppStrings.of(context);
    final controller = TextEditingController();
    String? problem;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(strings.text('duplicate_title')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 500,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    labelText: strings.text('duplicate_reason_prompt'),
                    errorText: problem,
                  ),
                ),
              ],
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
                if (text.length < 3 || text.length > 500) {
                  setDialogState(
                    () => problem = strings.text('reason_required'),
                  );
                  return;
                }
                Navigator.pop(context, text);
              },
              child: Text(strings.text('confirm_save')),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _offerReload(String message) async {
    final strings = AppStrings.of(context);
    final reload = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.text('stale_title')),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.text('reload')),
          ),
        ],
      ),
    );
    if (reload == true && mounted) {
      Navigator.of(
        context,
      ).pop(MemberReloadRequested(widget.controller.existing!.id));
    }
  }

  Widget _field(
    AppStrings strings,
    String field, {
    TextInputType? keyboard,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: _text[field],
      keyboardType: keyboard,
      enabled: !_saving,
      decoration: InputDecoration(
        labelText: strings.text(field),
        hintText: hint,
        errorText: _fieldErrors[field],
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final existing = widget.controller.existing;
    return AlertDialog(
      title: Text(
        existing == null
            ? strings.text('new_member')
            : '${strings.text('edit_member')} · ${existing.memberNo}',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _message!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              _field(strings, 'full_name'),
              _field(strings, 'mobile', keyboard: TextInputType.phone),
              _field(strings, 'alt_mobile', keyboard: TextInputType.phone),
              _field(strings, 'email', keyboard: TextInputType.emailAddress),
              _field(
                strings,
                'date_of_birth',
                keyboard: TextInputType.datetime,
                hint: 'YYYY-MM-DD',
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _gender,
                  decoration: InputDecoration(
                    labelText: strings.text('gender'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final g in _genders)
                      DropdownMenuItem(
                        value: g,
                        child: Text(strings.text('gender_$g')),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _gender = value),
                ),
              ),
              _field(strings, 'address_line1'),
              _field(strings, 'address_line2'),
              _field(strings, 'city'),
              _field(strings, 'district'),
              _field(strings, 'state'),
              _field(strings, 'pincode', keyboard: TextInputType.number),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _channel,
                decoration: InputDecoration(
                  labelText: strings.text('preferred_channel'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final c in _channels)
                    DropdownMenuItem(
                      value: c,
                      child: Text(strings.text('channel_$c')),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _channel = value ?? 'SMS'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(strings.text('cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.text('save')),
        ),
      ],
    );
  }
}
