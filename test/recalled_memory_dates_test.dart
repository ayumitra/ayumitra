// Recalled-memory date retention (MSG-103).
// Pure domain unit tests, synthetic data only: per-turn provided dates must
// survive recall — never replaced by memory.updatedAt, session dates, or the
// current date — with explicit older event dates kept verbatim, user-only
// origin, and chronological presentation.

import 'package:ayumitra/domain/conversations.dart';
import 'package:flutter_test/flutter_test.dart';

final _oct9 = DateTime.utc(2026, 10, 9);
final _oct13 = DateTime.utc(2026, 10, 13);
final _oct14 = DateTime.utc(2026, 10, 14);
final _oct15 = DateTime.utc(2026, 10, 15);

ConversationTurn _datedTurn(String id, String role, String text, DateTime at) =>
    ConversationTurn(id: id, role: role, text: text, createdAt: at);

ConversationSession _datedSession(
  String id,
  String profile,
  List<ConversationTurn> turns,
) => ConversationSession(
  id: id,
  profileId: profile,
  title: 'Synthetic conversation',
  createdAt: _oct9,
  updatedAt: _oct15,
  turns: turns,
);

/// Oct-13 observation with an explicit older event date, an unrelated newer
/// user message, and a fabricated assistant claim.
ConversationSession _hemoglobinSession() => _datedSession('s1', 'profile-a', [
  _datedTurn('u1', 'user', 'hemoglobin Hb 13 on 2026-03-14', _oct13),
  _datedTurn(
    'a1',
    'assistant',
    'Your hemoglobin is 17, a clear diagnosis of excellent health.',
    _oct13,
  ),
  _datedTurn('u2', 'user', 'What is the weather for my trip?', _oct14),
]);

void main() {
  test(
    'relevant recall keeps the provided date and event date, drops assistant fiction',
    () {
      final selected = selectRelevantUserContext(
        _hemoglobinSession(),
        query: 'hemoglobin',
      );

      // Provided date (turn createdAt) and explicit older event date survive.
      expect(selected.contains('2026-10-13'), true);
      expect(selected.contains('2026-03-14'), true);
      // Neither the memory/session stamp nor any other date replaces them.
      expect(selected.contains('2026-10-15'), false);
      expect(selected.contains('2026-10-09'), false);
      // Assistant text is never eligible, even when it matches the query.
      expect(selected.contains('17'), false);
      expect(selected.contains('clear diagnosis'), false);
      // User-only origin banner and chronological presentation hold.
      expect(selected.contains('user-stated'), true);
      expect(
        selected.indexOf('2026-10-13') < selected.indexOf('2026-10-14'),
        true,
      );
    },
  );

  test(
    'an update without an explicit event date retains its provided date',
    () {
      final session = _datedSession('s2', 'profile-a', [
        _datedTurn(
          'u1',
          'user',
          'I started a new vitamin this morning.',
          _oct13,
        ),
      ]);
      final selected = selectRelevantUserContext(session, query: 'vitamin');

      expect(selected.contains('2026-10-13'), true);
      expect(selected.contains('2026-10-15'), false);
      expect(selected.contains('user-stated'), true);
    },
  );

  test('stored memory stamps per-turn dates, never the session stamp', () {
    final memory = buildConversationMemory(_hemoglobinSession());

    expect(memory.updatedAt, _oct15);
    expect(memory.text.contains('2026-10-13'), true);
    expect(memory.text.contains('2026-10-14'), true);
    expect(memory.text.contains('2026-10-15'), false);
    expect(memory.text.contains('2026-03-14'), true);
    expect(memory.text.contains('17'), false);
  });
}
