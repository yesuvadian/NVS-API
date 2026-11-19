import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// How long a call may take before the user is told the server did not answer.
const apiTimeout = Duration(seconds: 20);

String _text(String language, String english, String tamil) =>
    language == 'ta' ? tamil : english;

/// Runs one HTTP call. Network failures (API down, CORS refusal, no
/// connection) and timeouts become an [AuthException] with a readable
/// message instead of an uncaught exception.
Future<http.Response> sendApiRequest(
  Future<http.Response> Function() call,
  String language,
) async {
  try {
    return await call().timeout(apiTimeout);
  } on TimeoutException {
    throw AuthException(
      _text(
        language,
        'The server did not respond in time. Check your connection and try again.',
        'சேவையகம் நேரத்திற்குள் பதிலளிக்கவில்லை. இணைப்பைச் சரிபார்த்து மீண்டும் முயற்சிக்கவும்.',
      ),
      code: 'NETWORK_TIMEOUT',
    );
  } on http.ClientException {
    throw AuthException(
      _text(
        language,
        'Cannot reach the CFMS server. Check that it is running and try again.',
        'CFMS சேவையகத்தை அணுக முடியவில்லை. அது இயங்குகிறதா எனச் சரிபார்த்து மீண்டும் முயற்சிக்கவும்.',
      ),
      code: 'NETWORK_ERROR',
    );
  }
}

/// An HTTP client that applies [sendApiRequest]'s timeout and network-error
/// handling to every call. The message language comes from the request's
/// Accept-Language header.
class ApiHttpClient extends http.BaseClient {
  ApiHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final language = request.headers['Accept-Language'] ?? 'en';
    final response = await sendApiRequest(
      () async => http.Response.fromStream(await _inner.send(request)),
      language,
    );
    return http.StreamedResponse(
      http.ByteStream.fromBytes(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: response.request ?? request,
      reasonPhrase: response.reasonPhrase,
      contentLength: response.bodyBytes.length,
    );
  }

  @override
  void close() => _inner.close();
}

/// Decodes a JSON response body; null for an empty body.
dynamic decodeApiBody(http.Response response, String language) {
  if (response.body.isEmpty) return null;
  try {
    return jsonDecode(response.body);
  } on FormatException {
    throw AuthException(
      _text(
        language,
        'The server sent an unexpected response. Please try again.',
        'சேவையகத்திலிருந்து எதிர்பாராத பதில் வந்தது. மீண்டும் முயற்சிக்கவும்.',
      ),
      code: 'BAD_RESPONSE',
    );
  }
}

/// Returns the decoded body of a 2xx response, or throws the API's coded,
/// localised error (`detail.shortCode` / `detail.message`).
dynamic parseApiResponse(http.Response response, String language) {
  if (response.statusCode >= 200 && response.statusCode < 300) {
    return decodeApiBody(response, language);
  }
  throwApiError(response, language);
}

Never throwApiError(http.Response response, String language) {
  dynamic detail;
  try {
    final body = jsonDecode(response.body);
    if (body is Map<String, dynamic>) detail = body['detail'];
  } catch (_) {}
  if (detail is Map && detail['message'] is String) {
    throw AuthException(
      detail['message'] as String,
      code: detail['shortCode'] as String?,
    );
  }
  if (detail is List) {
    // Older API builds return FastAPI's default validation list.
    throw AuthException(
      _text(
        language,
        'Some details are not in the correct format. Check them and try again.',
        'சில விவரங்கள் சரியான வடிவத்தில் இல்லை. சரிபார்த்து மீண்டும் முயற்சிக்கவும்.',
      ),
      code: 'INVALID_DATA',
    );
  }
  throw AuthException(
    _text(
      language,
      'Request failed. Please try again.',
      'கோரிக்கை தோல்வியடைந்தது. மீண்டும் முயற்சிக்கவும்.',
    ),
  );
}
