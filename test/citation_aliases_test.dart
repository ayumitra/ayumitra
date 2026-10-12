// Tests for per-call citation aliases (MSG-073). Synthetic IDs only.

import 'package:ayumitra/domain/citation_aliases.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('building', () {
    test('numbers stably S1..Sn, preserves order, dedups', () {
      final aliases = CitationAliases.fromCanonical(['b', 'a', 'b', 'c']);
      expect(aliases.aliasToCanonical, {'S1': 'b', 'S2': 'a', 'S3': 'c'});
      expect(aliases.aliasFor('a'), 'S2');
    });

    test('canonical IDs shaped like aliases refuse to build', () {
      expect(
        () => CitationAliases.fromCanonical(['r1/p1-l1', 'S1']),
        throwsStateError,
      );
    });

    test('empty list builds empty, validates nothing', () {
      final aliases = CitationAliases.fromCanonical([]);
      expect(aliases.aliases, isEmpty);
      expect(aliases.validate('No refs here', {}), isFalse);
    });
  });

  group('validation', () {
    final aliases = CitationAliases.fromCanonical([
      'report-a/p1-l1',
      'web-1',
      'conversation:s9',
      'user-history',
    ]);

    test('accepts all-alias and mixed alias+canonical refs', () {
      expect(
        aliases.validate('Value rose [S1] per label [web-1].', {
          'report-a/p1-l1',
          'web-1',
          'conversation:s9',
          'user-history',
        }),
        isTrue,
      );
    });

    test('rejects unknown, partial, and empty refs', () {
      const allowed = {'report-a/p1-l1', 'web-1'};
      expect(aliases.validate('Claim [S9].', allowed), isFalse);
      // Prefix of a real sourceLineId: never a match.
      expect(aliases.validate('Claim [report-a/p1-l].', allowed), isFalse);
      // Suffix invention on a real alias: never a match.
      expect(aliases.validate('Claim [S1x].', allowed), isFalse);
      expect(aliases.validate('No brackets at all.', allowed), isFalse);
    });

    test('alias for an unlisted ID throws instead of guessing', () {
      expect(() => aliases.aliasFor('nope'), throwsStateError);
    });
  });

  group('resolution', () {
    final aliases = CitationAliases.fromCanonical(['report-a/p1-l1', 'web-1']);

    test('rewrites known aliases exactly, leaves unknown intact', () {
      expect(
        aliases.resolveText('See [S1] and [web-1], not [S3].'),
        'See [report-a/p1-l1] and [web-1], not [S3].',
      );
    });

    test('S1 never collides with S10', () {
      final many = CitationAliases.fromCanonical([
        for (var i = 0; i < 10; i++) 'id-$i',
      ]);
      expect(
        many.resolveText('[S1] then [S10] then [S11].'),
        '[id-0] then [id-9] then [S11].',
      );
    });

    test('resolveRef prefers exactness over guessing', () {
      const allowed = {'report-a/p1-l1'};
      expect(aliases.resolveRef('S1', allowed), 'report-a/p1-l1');
      expect(aliases.resolveRef('report-a/p1-l1', allowed), 'report-a/p1-l1');
      expect(aliases.resolveRef('web-1', allowed), isNull);
      expect(aliases.resolveRef('report-a/p1-l', allowed), isNull);
    });
  });

  group('call scoping', () {
    test('same token maps independently per call and profile', () {
      final first = CitationAliases.fromCanonical(['profile-a-report']);
      final second = CitationAliases.fromCanonical(['profile-b-report']);
      expect(first.resolveText('[S1]'), '[profile-a-report]');
      expect(second.resolveText('[S1]'), '[profile-b-report]');
      // Profile B's refs never validate against profile A's allowlist.
      expect(first.validate('[S1]', {'profile-b-report'}), isFalse);
    });

    test('instruction carries legend and example, stays short', () {
      final aliases = CitationAliases.fromCanonical(['report-a/p1-l1']);
      final guide = aliases.instruction();
      expect(guide, contains('[S1]'));
      expect(guide, isNot(contains('report-a/p1-l1')));
      expect(guide, contains('exact sourceId'));
      expect(guide.length, lessThan(500));
    });
  });
}
