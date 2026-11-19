import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'app_config_service.dart';

/// A new Idempotency-Key: 32 hex characters from a secure random source
/// (matches the API's `^[A-Za-z0-9_.:-]{8,100}$`).
String newIdempotencyKey([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Member fields the form edits, in the API's names.
const memberFormFields = [
  'full_name',
  'mobile',
  'alt_mobile',
  'email',
  'gender',
  'date_of_birth',
  'address_line1',
  'address_line2',
  'city',
  'district',
  'state',
  'pincode',
  'preferred_channel',
];

class Member {
  const Member({
    required this.id,
    required this.memberNo,
    required this.fullName,
    required this.status,
    this.rowVersion = 1,
    this.values = const {},
  });
  final String id;
  final String memberNo;
  final String fullName;
  final String status;
  final int rowVersion;

  /// Editable fields as returned by the API (see [memberFormFields]).
  final Map<String, Object?> values;

  String? get mobile => values['mobile'] as String?;
  String? get city => values['city'] as String?;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: json['id'] as String,
    memberNo: json['member_no'] as String,
    fullName: json['full_name'] as String,
    status: json['status'] as String,
    rowVersion: json['row_version'] as int? ?? 1,
    values: {for (final field in memberFormFields) field: json[field]},
  );
}

class MemberPage {
  const MemberPage({
    required this.items,
    required this.hasMore,
    this.nextOffset,
  });
  final List<Member> items;
  final bool hasMore;
  final int? nextOffset;

  factory MemberPage.fromJson(Map<String, dynamic> json) => MemberPage(
    items: [
      for (final row in json['items'] as List<dynamic>? ?? const [])
        Member.fromJson(row as Map<String, dynamic>),
    ],
    hasMore: json['has_more'] as bool? ?? false,
    nextOffset: json['next_offset'] as int?,
  );
}

class MemberService {
  MemberService(this.config, {http.Client? client})
    : _client = client ?? ApiHttpClient();
  final AppConfig config;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) => config.apiBaseUrl
      .resolve('${config.apiPrefix}$path')
      .replace(queryParameters: query);

  Map<String, String> _headers(String token, String language) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Accept-Language': language,
    'Authorization': 'Bearer $token',
  };

  Future<MemberPage> list(
    String token,
    String language, {
    String? query,
    String? status,
    required int limit,
    int offset = 0,
  }) async {
    final response = await _client.get(
      _uri('/members', {
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        'status': ?status,
        'limit': '$limit',
        'offset': '$offset',
      }),
      headers: _headers(token, language),
    );
    return MemberPage.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }

  Future<Member> get(String token, String language, String id) async {
    final response = await _client.get(
      _uri('/members/$id'),
      headers: _headers(token, language),
    );
    return Member.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }

  Future<Member> create(
    String token,
    String language,
    Map<String, Object?> fields, {
    required String idempotencyKey,
  }) async {
    final response = await _client.post(
      _uri('/members'),
      headers: {
        ..._headers(token, language),
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode(fields),
    );
    return Member.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }

  Future<Member> update(
    String token,
    String language,
    String id,
    Map<String, Object?> changes, {
    required int rowVersion,
  }) async {
    final response = await _client.patch(
      _uri('/members/$id'),
      headers: {
        ..._headers(token, language),
        'X-Expected-Row-Version': '$rowVersion',
      },
      body: jsonEncode(changes),
    );
    return Member.fromJson(
      parseApiResponse(response, language) as Map<String, dynamic>,
    );
  }
}
