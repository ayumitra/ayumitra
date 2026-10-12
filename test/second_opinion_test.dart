// Sub-owned tests: explicit-tap second-opinion export (user request).
// Synthetic data only. No network, no real patient data.

import 'dart:convert';

import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/second_opinion.dart';
import 'package:flutter_test/flutter_test.dart';

final _dob = DateTime(2021, 4, 18);
Profile _profile() => Profile(
  id: 'p1',
  name: 'Synthetic Child',
  history: 'Synthetic history.',
  isChild: true,
  dateOfBirth: _dob,
);

ConversationSession _session() => ConversationSession(
  id: 's1',
  profileId: 'p1',
  title: 'Fever questions',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  turns: [
    ConversationTurn(
      id: 't1',
      role: 'user',
      text: 'My child has fever, what should I ask the doctor?',
      createdAt: DateTime.utc(2026, 10, 1),
      reportCitations: const ['r1/p1-l1'],
    ),
    ConversationTurn(
      id: 't2',
      role: 'assistant',
      text: 'Local draft citing Hb 11.2 g/dL [r1/p1-l1].',
      createdAt: DateTime.utc(2026, 10, 2),
      webSources: [
        ConversationWebSource(
          id: 'web-1',
          title: 'Synthetic label',
          url: 'https://example.org/label',
          excerpt: 'Synthetic excerpt.',
          retrievedAt: DateTime.utc(2026, 10, 12),
        ),
      ],
    ),
  ],
);

Report _report() => Report(
  id: 'r1',
  profileId: 'p1',
  name: 'r1.pdf',
  extension: 'pdf',
  digest: 'digest-r1',
  importedAt: DateTime.utc(2026, 10, 12),
  lines: const [
    SourceLine(id: 'p1-l1', page: 1, text: 'Hb 11.2 g/dL [12.0-16.0]'),
  ],
);

void main() {
  test('pack carries transcript, citations, web sources, and warnings', () {
    final pack = buildSecondOpinionPack(
      profile: _profile(),
      session: _session(),
      reports: [_report()],
    );
    expect(pack.markdown, contains('review before sending'));
    expect(pack.markdown, contains('My child has fever'));
    expect(pack.markdown, contains('[r1/p1-l1]'));
    expect(pack.markdown, contains('Hb 11.2 g/dL'));
    expect(pack.markdown, contains('https://example.org/label'));
    expect(pack.markdown, contains('2026-10-12'));
    expect(pack.reportIds, ['r1']);
    expect(pack.truncated, isFalse);
  });

  test('long packs truncate explicitly, never silently', () {
    final pack = buildSecondOpinionPack(
      profile: _profile(),
      session: _session(),
      reports: [_report()],
      maxChars: 200,
    );
    expect(pack.truncated, isTrue);
    expect(pack.markdown, contains('Truncated for sharing'));
    expect(pack.markdown.length, greaterThan(200));
    expect(pack.markdown.length, lessThan(400));
  });

  test('identifier hints flag name/email without echoing values', () {
    final session = ConversationSession(
      id: 's1',
      profileId: 'p1',
      title: 'T',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
      turns: [
        ConversationTurn(
          id: 't1',
          role: 'user',
          text: 'Synthetic Child contact zephyr@example.com 9876543210',
          createdAt: DateTime.utc(2026, 10, 1),
        ),
      ],
    );
    final pack = buildSecondOpinionPack(
      profile: _profile(),
      session: session,
      reports: const [],
    );
    expect(pack.identifierHints, contains('email address'));
    expect(pack.identifierHints, contains('long number (phone/MRN/ID?)'));
    expect(pack.identifierHints, contains('profile name'));
    for (final hint in pack.identifierHints) {
      expect(hint, isNot(contains('zephyr@example.com')));
      expect(hint, isNot(contains('9876543210')));
    }
  });

  test('cross-profile sessions are refused', () {
    final other = ConversationSession(
      id: 's9',
      profileId: 'p2',
      title: 'T',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
    );
    expect(
      () => buildSecondOpinionPack(
        profile: _profile(),
        session: other,
        reports: const [],
      ),
      throwsStateError,
    );
  });

  test('audit stores metadata only; vault keeps it across decode', () {
    final audit = SecondOpinionAudit(
      id: 'e1',
      profileId: 'p1',
      sessionId: 's1',
      target: 'chatgpt',
      reportIds: const ['r1'],
      reviewed: true,
      createdAt: DateTime.utc(2026, 10, 12),
    );
    expect(audit.toJson().keys, isNot(contains('markdown')));
    final data = VaultData.decode(
      jsonEncode(
        VaultData(
          exports: [
            SecondOpinionAudit(
              id: 'e1',
              profileId: 'p1',
              sessionId: 's1',
              target: 'chatgpt',
              reportIds: const ['r1'],
              reviewed: true,
              createdAt: DateTime.utc(2026, 10, 12),
            ),
          ],
        ).toJson(),
      ),
    );
    expect(data.exports.single.target, 'chatgpt');
    expect(data.exports.single.reportIds, ['r1']);
    // Backward compatible: vaults written before exports gain an empty log.
    final legacy = VaultData.decode('{"schema":2,"profiles":[],"reports":[]}');
    expect(legacy.exports, isEmpty);
  });
}
