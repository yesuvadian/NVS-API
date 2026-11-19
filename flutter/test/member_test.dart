import 'dart:convert';

import 'package:cfms_portal/providers/member_provider.dart';
import 'package:cfms_portal/services/app_config_service.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:cfms_portal/services/member_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final config = AppConfig(
  appName: 'CFMS',
  apiBaseUrl: Uri.parse('http://localhost:8000'),
  apiPrefix: '/api/v1',
  defaultLocale: 'en',
  supportedLocales: const ['en', 'ta'],
  themeMode: 'system',
  defaultPageSize: 15,
  maxPageSize: 100,
);

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> memberJson({
  String id = 'm1',
  String name = 'Kavitha R',
  String? mobile = '9876543210',
  int rowVersion = 1,
}) => {
  'id': id,
  'member_no': 'MEM-0001',
  'full_name': name,
  'mobile': mobile,
  'city': 'Chennai',
  'status': 'APPLIED',
  'preferred_channel': 'SMS',
  'row_version': rowVersion,
};

http.Response apiError(
  int status,
  String code,
  String message, [
  Map<String, dynamic>? details,
]) => json({
  'detail': {'shortCode': code, 'message': message, 'details': ?details},
}, status);

int _keys = 0;
String countingKey() => 'key-${++_keys}-0000000000000000';

void main() {
  setUp(() => _keys = 0);

  group('create', () {
    test(
      'sends an Idempotency-Key and reuses it when the same submission is retried',
      () async {
        final requests = <http.Request>[];
        var calls = 0;
        final service = MemberService(
          config,
          client: MockClient((request) async {
            requests.add(request);
            calls++;
            if (calls == 1) {
              return apiError(503, 'SERVICE_UNAVAILABLE', 'Try again.');
            }
            return json(memberJson(), 201);
          }),
        );
        final form = MemberFormController(
          service,
          'tok',
          () => 'en',
          keyFactory: countingKey,
        );
        final fields = {
          'full_name': ' Kavitha R ',
          'mobile': '9876543210',
          'email': '',
        };

        final first = await form.submit(fields);
        final retry = await form.submit(fields);

        expect(first.outcome, MemberSubmitOutcome.failed);
        expect(retry.outcome, MemberSubmitOutcome.saved);
        expect(requests.map((r) => r.headers['Idempotency-Key']).toSet(), {
          'key-1-0000000000000000',
        });
        expect(jsonDecode(requests.last.body), {
          'full_name': 'Kavitha R',
          'mobile': '9876543210',
        });
      },
    );

    test('a changed payload gets a new key', () async {
      final keys = <String?>[];
      final service = MemberService(
        config,
        client: MockClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          return apiError(
            422,
            'INVALID_DATA',
            'mobile is not in the correct format.',
            {
              'errors': [
                {
                  'field': 'mobile',
                  'type': 'string_too_short',
                  'message': 'String should have at least 7 characters',
                },
              ],
            },
          );
        }),
      );
      final form = MemberFormController(
        service,
        'tok',
        () => 'en',
        keyFactory: countingKey,
      );

      final invalid = await form.submit({
        'full_name': 'Kavitha R',
        'mobile': '98',
      });
      await form.submit({'full_name': 'Kavitha R', 'mobile': '9876543210'});

      expect(invalid.outcome, MemberSubmitOutcome.invalid);
      expect(invalid.fieldErrors, {
        'mobile': 'String should have at least 7 characters',
      });
      expect(keys, ['key-1-0000000000000000', 'key-2-0000000000000000']);
    });

    test('duplicate member is confirmed with a reason and a new key', () async {
      final bodies = <Map<String, dynamic>>[];
      final keys = <String?>[];
      final service = MemberService(
        config,
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          keys.add(request.headers['Idempotency-Key']);
          if (bodies.length == 1) {
            return apiError(
              409,
              'DUPLICATE_MEMBER',
              'A member with the same mobile number already exists.',
            );
          }
          return json(memberJson(), 201);
        }),
      );
      final form = MemberFormController(
        service,
        'tok',
        () => 'en',
        keyFactory: countingKey,
      );
      final fields = {'full_name': 'Kavitha R', 'mobile': '9876543210'};

      final duplicate = await form.submit(fields);
      expect(duplicate.outcome, MemberSubmitOutcome.duplicate);
      expect(duplicate.message, contains('already exists'));

      final confirmed = await form.submit(
        fields,
        duplicateReason: ' Sister, same family phone ',
      );
      expect(confirmed.outcome, MemberSubmitOutcome.saved);
      expect(bodies.first.containsKey('duplicate_override_reason'), isFalse);
      expect(
        bodies.last['duplicate_override_reason'],
        'Sister, same family phone',
      );
      expect(keys[0], isNot(keys[1]));
    });

    test('generated keys match the API pattern', () {
      final key = newIdempotencyKey();
      expect(RegExp(r'^[A-Za-z0-9_.:-]{8,100}$').hasMatch(key), isTrue);
      expect(key.length, 32);
      expect(newIdempotencyKey(), isNot(key));
    });
  });

  group('edit', () {
    test('sends only changed fields with X-Expected-Row-Version', () async {
      late http.Request seen;
      final service = MemberService(
        config,
        client: MockClient((request) async {
          seen = request;
          return json(memberJson(name: 'Kavitha Raman', rowVersion: 4));
        }),
      );
      final existing = Member.fromJson(memberJson(rowVersion: 3));
      final form = MemberFormController(
        service,
        'tok',
        () => 'en',
        existing: existing,
      );

      final unchanged = await form.submit(Map.of(existing.values));
      expect(unchanged.outcome, MemberSubmitOutcome.noChanges);

      final result = await form.submit({
        ...existing.values,
        'full_name': 'Kavitha Raman',
      });
      expect(result.outcome, MemberSubmitOutcome.saved);
      expect(result.member!.rowVersion, 4);
      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/api/v1/members/m1');
      expect(seen.headers['X-Expected-Row-Version'], '3');
      expect(seen.headers.containsKey('Idempotency-Key'), isFalse);
      expect(jsonDecode(seen.body), {'full_name': 'Kavitha Raman'});
    });

    test('a record changed by someone else is reported as stale', () async {
      final service = MemberService(
        config,
        client: MockClient(
          (_) async => apiError(
            409,
            'STALE_RECORD',
            'This record was changed after you opened it.',
          ),
        ),
      );
      final existing = Member.fromJson(memberJson());
      final form = MemberFormController(
        service,
        'tok',
        () => 'en',
        existing: existing,
      );

      final result = await form.submit({...existing.values, 'city': 'Madurai'});

      expect(result.outcome, MemberSubmitOutcome.stale);
      expect(result.message, contains('changed after you opened it'));
    });

    test('duplicate on edit adds the override reason', () async {
      final bodies = <Map<String, dynamic>>[];
      final service = MemberService(
        config,
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return bodies.length == 1
              ? apiError(409, 'DUPLICATE_MEMBER', 'Duplicate.')
              : json(memberJson(mobile: '9000000000', rowVersion: 2));
        }),
      );
      final existing = Member.fromJson(memberJson());
      final form = MemberFormController(
        service,
        'tok',
        () => 'en',
        existing: existing,
      );
      final fields = {...existing.values, 'mobile': '9000000000'};

      expect(
        (await form.submit(fields)).outcome,
        MemberSubmitOutcome.duplicate,
      );
      expect(
        (await form.submit(
          fields,
          duplicateReason: 'Different person',
        )).outcome,
        MemberSubmitOutcome.saved,
      );
      expect(bodies.last, {
        'mobile': '9000000000',
        'duplicate_override_reason': 'Different person',
      });
    });
  });

  group('list', () {
    test(
      'uses the organisation page size, search, status and next_offset',
      () async {
        final urls = <Uri>[];
        final service = MemberService(
          config,
          client: MockClient((request) async {
            urls.add(request.url);
            final offset = int.parse(request.url.queryParameters['offset']!);
            return json({
              'items': [
                memberJson(id: 'm${offset + 1}'),
                memberJson(id: 'm${offset + 2}'),
              ],
              'limit': 2,
              'offset': offset,
              'has_more': offset == 0,
              'next_offset': offset == 0 ? 2 : null,
            });
          }),
        );
        final list = MemberListProvider(
          service,
          'tok',
          () => 'en',
          loadPageSize: () async => 2,
        );

        list.query = 'kavi';
        list.status = 'ACTIVE';
        await list.load();
        expect(list.members.map((m) => m.id), ['m1', 'm2']);
        expect(list.hasMore, isTrue);
        expect(urls.first.queryParameters, {
          'q': 'kavi',
          'status': 'ACTIVE',
          'limit': '2',
          'offset': '0',
        });

        await list.loadMore();
        expect(list.members.map((m) => m.id), ['m1', 'm2', 'm3', 'm4']);
        expect(list.hasMore, isFalse);
        expect(urls.last.queryParameters['offset'], '2');

        await list.loadMore(); // nothing more to load
        expect(urls, hasLength(2));
      },
    );

    test(
      'falls back to the default page size and reports session expiry',
      () async {
        String? expired;
        final list = MemberListProvider(
          MemberService(
            config,
            client: MockClient((request) async {
              expect(request.url.queryParameters['limit'], '15');
              return apiError(
                401,
                'SESSION_EXPIRED',
                'Your session has ended.',
              );
            }),
          ),
          'tok',
          () => 'en',
          loadPageSize: () async =>
              throw const AuthException('No access', code: 'NO_PRIVILEGE'),
          onSessionExpired: (message, code) => expired = code,
        );

        await list.load();

        expect(list.pageSize, 15);
        expect(list.error, 'Your session has ended.');
        expect(expired, 'SESSION_EXPIRED');
      },
    );
  });

  test('client validation', () {
    expect(validateMemberFields({'full_name': 'K'}), {
      'full_name': 'validation_full_name',
    });
    expect(
      validateMemberFields({
        'full_name': 'Kavitha R',
        'mobile': '12',
        'email': 'not-an-email',
        'pincode': '0600',
        'date_of_birth': '2099-01-01',
      }),
      {
        'mobile': 'validation_mobile',
        'email': 'validation_email',
        'pincode': 'validation_pincode',
        'date_of_birth': 'validation_date',
      },
    );
    expect(
      validateMemberFields({
        'full_name': 'Kavitha R',
        'mobile': '+91 98765 43210',
        'email': 'k@example.com',
        'pincode': '600001',
        'date_of_birth': '1985-04-12',
      }),
      isEmpty,
    );
  });
}
