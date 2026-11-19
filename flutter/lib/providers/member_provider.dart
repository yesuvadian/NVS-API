import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../services/member_service.dart';

const _sessionCodes = {'SESSION_EXPIRED', 'NOT_SIGNED_IN'};

/// Member list with search, status filter and "Load more" paging.
class MemberListProvider extends ChangeNotifier {
  MemberListProvider(
    this.service,
    this.token,
    this.language, {
    this.loadPageSize,
    this.defaultPageSize = 15,
    this.onSessionExpired,
  });

  final MemberService service;
  final String token;
  final String Function() language;

  /// Reads the organisation's rows-per-page setting; [defaultPageSize] is
  /// used when it is not available.
  final Future<int> Function()? loadPageSize;
  final int defaultPageSize;
  final void Function(String message, String code)? onSessionExpired;

  int? _pageSize;
  List<Member> members = [];
  String query = '';
  String? status;
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasMore = false;
  int? nextOffset;
  String? error;

  int get pageSize => _pageSize ?? defaultPageSize;

  Future<void> _resolvePageSize() async {
    if (_pageSize != null) return;
    try {
      _pageSize = await loadPageSize?.call() ?? defaultPageSize;
    } on AuthException {
      _pageSize = defaultPageSize;
    }
  }

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      await _resolvePageSize();
      final page = await service.list(
        token,
        language(),
        query: query,
        status: status,
        limit: pageSize,
      );
      members = page.items;
      hasMore = page.hasMore;
      nextOffset = page.nextOffset;
    } on AuthException catch (e) {
      _setError(e);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (isLoading || isLoadingMore || !hasMore || nextOffset == null) return;
    isLoadingMore = true;
    error = null;
    notifyListeners();
    try {
      final page = await service.list(
        token,
        language(),
        query: query,
        status: status,
        limit: pageSize,
        offset: nextOffset!,
      );
      members = [...members, ...page.items];
      hasMore = page.hasMore;
      nextOffset = page.nextOffset;
    } on AuthException catch (e) {
      _setError(e);
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> search(String value) {
    query = value;
    return load();
  }

  Future<void> filterStatus(String? value) {
    status = value;
    return load();
  }

  void _setError(AuthException e) {
    error = e.message;
    if (_sessionCodes.contains(e.code)) {
      onSessionExpired?.call(e.message, e.code!);
    }
  }
}

enum MemberSubmitOutcome { saved, noChanges, duplicate, stale, invalid, failed }

class MemberSubmitResult {
  const MemberSubmitResult(
    this.outcome, {
    this.member,
    this.message,
    this.fieldErrors = const {},
  });
  final MemberSubmitOutcome outcome;
  final Member? member;
  final String? message;
  final Map<String, String> fieldErrors;
}

/// Client-side checks; returns field -> AppStrings key of the problem.
Map<String, String> validateMemberFields(Map<String, Object?> fields) {
  String text(String key) => '${fields[key] ?? ''}'.trim();
  final errors = <String, String>{};
  final name = text('full_name');
  if (name.length < 2 || name.length > 200) {
    errors['full_name'] = 'validation_full_name';
  }
  for (final key in ['mobile', 'alt_mobile']) {
    final value = text(key);
    if (value.isNotEmpty && !RegExp(r'^\+?[0-9 -]{7,20}$').hasMatch(value)) {
      errors[key] = 'validation_mobile';
    }
  }
  final email = text('email');
  if (email.isNotEmpty &&
      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
    errors['email'] = 'validation_email';
  }
  final pincode = text('pincode');
  if (pincode.isNotEmpty && !RegExp(r'^[1-9][0-9]{5}$').hasMatch(pincode)) {
    errors['pincode'] = 'validation_pincode';
  }
  final birth = text('date_of_birth');
  if (birth.isNotEmpty) {
    final parsed = DateTime.tryParse(birth);
    if (parsed == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(birth) ||
        parsed.isAfter(DateTime.now())) {
      errors['date_of_birth'] = 'validation_date';
    }
  }
  return errors;
}

/// Trimmed values with blanks as null.
Map<String, Object?> _clean(Map<String, Object?> fields) => {
  for (final entry in fields.entries)
    entry.key: entry.value is String
        ? ((entry.value as String).trim().isEmpty
              ? null
              : (entry.value as String).trim())
        : entry.value,
};

/// Submits one member form (create or edit) with the API's concurrency rules:
/// a create carries an Idempotency-Key made when the form opened and reused
/// when the same submission is retried (a changed payload gets a new key);
/// an edit sends only changed fields with X-Expected-Row-Version.
class MemberFormController {
  MemberFormController(
    this.service,
    this.token,
    this.language, {
    this.existing,
    this.onSessionExpired,
    String Function()? keyFactory,
  }) : _newKey = keyFactory ?? newIdempotencyKey {
    _key = _newKey();
  }

  final MemberService service;
  final String token;
  final String Function() language;
  final Member? existing;
  final void Function(String message, String code)? onSessionExpired;
  final String Function() _newKey;
  late String _key;
  String? _lastPayload;

  bool get isEdit => existing != null;
  String get idempotencyKey => _key;

  /// Fields that differ from the opened record (edit only).
  Map<String, Object?> changesFrom(Map<String, Object?> fields) {
    final cleaned = _clean(fields);
    final before = _clean(existing?.values ?? const {});
    return {
      for (final entry in cleaned.entries)
        if (entry.value != before[entry.key]) entry.key: entry.value,
    };
  }

  Future<MemberSubmitResult> submit(
    Map<String, Object?> fields, {
    String? duplicateReason,
  }) async {
    final payload = isEdit
        ? changesFrom(fields)
        : {
            for (final entry in _clean(fields).entries)
              if (entry.value != null) entry.key: entry.value,
          };
    if (isEdit && payload.isEmpty) {
      return const MemberSubmitResult(MemberSubmitOutcome.noChanges);
    }
    if (duplicateReason != null) {
      payload['duplicate_override_reason'] = duplicateReason.trim();
    }
    try {
      final Member saved;
      if (isEdit) {
        saved = await service.update(
          token,
          language(),
          existing!.id,
          payload,
          rowVersion: existing!.rowVersion,
        );
      } else {
        final encoded = jsonEncode(payload);
        if (_lastPayload != null && _lastPayload != encoded) _key = _newKey();
        _lastPayload = encoded;
        saved = await service.create(
          token,
          language(),
          payload,
          idempotencyKey: _key,
        );
      }
      return MemberSubmitResult(MemberSubmitOutcome.saved, member: saved);
    } on AuthException catch (e) {
      if (_sessionCodes.contains(e.code)) {
        onSessionExpired?.call(e.message, e.code!);
      }
      final outcome = switch (e.code) {
        'DUPLICATE_MEMBER' => MemberSubmitOutcome.duplicate,
        'STALE_RECORD' => MemberSubmitOutcome.stale,
        'INVALID_DATA' => MemberSubmitOutcome.invalid,
        _ => MemberSubmitOutcome.failed,
      };
      return MemberSubmitResult(
        outcome,
        message: e.message,
        fieldErrors: e.fieldErrors,
      );
    }
  }
}
