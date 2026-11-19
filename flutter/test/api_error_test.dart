import 'dart:async';

import 'package:cfms_portal/services/api_error.dart';
import 'package:cfms_portal/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  http.Request request() =>
      http.Request('GET', Uri.parse('http://x/y'))
        ..headers['Accept-Language'] = 'en';

  test('network failure becomes a readable AuthException', () async {
    final client = ApiHttpClient(
      MockClient((_) async => throw http.ClientException('refused')),
    );
    expect(
      () => client.send(request()),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'NETWORK_ERROR'),
      ),
    );
  });

  test('timeout becomes a readable AuthException', () async {
    expect(
      () => sendApiRequest(
        () => Future<http.Response>.error(TimeoutException('slow')),
        'en',
      ),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'NETWORK_TIMEOUT'),
      ),
    );
  });

  test('coded API error keeps its message and short code', () {
    final response = http.Response(
      '{"detail":{"shortCode":"INVALID_DATA","message":"code is not in the correct format."}}',
      400,
    );
    expect(
      () => throwApiError(response, 'en'),
      throwsA(
        isA<AuthException>()
            .having((e) => e.code, 'code', 'INVALID_DATA')
            .having((e) => e.message, 'message', contains('code')),
      ),
    );
  });

  test('FastAPI default validation list is still readable', () {
    final response = http.Response('{"detail":[{"loc":["body","code"]}]}', 422);
    expect(
      () => throwApiError(response, 'en'),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'INVALID_DATA'),
      ),
    );
  });
}
