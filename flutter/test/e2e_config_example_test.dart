// Guard: the committed example config must never contain real passwords.
// Real accounts belong in the git-ignored e2e_config.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('e2e_config.example.json has only empty passwords', () {
    final example =
        jsonDecode(File('e2e_config.example.json').readAsStringSync())
            as Map<String, dynamic>;
    final passwords = {
      for (final entry in example.entries)
        if (entry.key.endsWith('_PASSWORD')) entry.key: entry.value,
    };
    expect(passwords, isNotEmpty);
    final filled = [
      for (final e in passwords.entries)
        if ('${e.value}'.isNotEmpty) e.key,
    ];
    expect(
      filled,
      isEmpty,
      reason:
          'Put real passwords in e2e_config.json (git-ignored), never in the example: $filled',
    );
  });

  test('the real e2e_config.json is git-ignored', () {
    final ignore = File('.gitignore').readAsLinesSync().map((l) => l.trim());
    expect(ignore, contains('e2e_config.json'));
  });
}
