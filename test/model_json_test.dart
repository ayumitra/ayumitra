// Shared fence-hygiene checks. Synthetic only: plain strings, no models.
import 'package:ayumitra/domain/model_json.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strips a json fence pair', () {
    expect(unfenceJson('```json\n{"a":1}\n```'), '{"a":1}');
  });

  test('strips a bare fence pair', () {
    expect(unfenceJson('```\n{"a":1}\n```'), '{"a":1}');
  });

  test('fence language tag is case-insensitive', () {
    expect(unfenceJson('```JSON\n{"a":1}\n```'), '{"a":1}');
    expect(unfenceJson('```Json\n{"a":1}\n```'), '{"a":1}');
  });

  test('trims surrounding whitespace', () {
    expect(unfenceJson('  \n{"a":1}  \n'), '{"a":1}');
  });

  test('leaves non-fenced output byte-identical', () {
    expect(unfenceJson('{"a":1}'), '{"a":1}');
    expect(unfenceJson('not json at all'), 'not json at all');
  });

  test('does not touch interior fences', () {
    expect(unfenceJson('{"code":"a ``` b"}'), '{"code":"a ``` b"}');
  });

  test('leaves malformed content for strict validators', () {
    expect(unfenceJson('```json\n{"a":}\n```'), '{"a":}');
  });
}
