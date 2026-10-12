// Sub-owned tests for MSG-038: DOB profiles, exact ages, VaultData schema 2.
// Written by Sub; executed by Main (no concurrent Flutter runs).
// All data synthetic. Uses public APIs only.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ayumitra/domain/conversations.dart';
import 'package:ayumitra/domain/records.dart';

Profile _dobProfile(String id, DateTime dob) => Profile(
  id: id,
  name: 'Synthetic Child',
  history: 'Synthetic history.',
  isChild: true,
  dateOfBirth: dob,
);

void main() {
  group('exact DOB ages', () {
    test('years from age 1, months for infants', () {
      expect(
        ageAtEvent(
          _dobProfile('p', DateTime(2022, 5, 1)),
          DateTime(2025, 6, 1),
        ),
        'Age 3',
      );
      expect(
        ageAtEvent(
          _dobProfile('p', DateTime(2025, 1, 15)),
          DateTime(2025, 6, 10),
        ),
        'Age 4 months',
      );
      expect(
        ageAtEvent(
          _dobProfile('p', DateTime(2025, 6, 10)),
          DateTime(2025, 6, 10),
        ),
        'Age 0 months',
      );
      expect(
        ageAtEvent(
          _dobProfile('p', DateTime(2024, 1, 15)),
          DateTime(2025, 1, 15),
        ),
        'Age 1',
      );
    });

    test('leap-day births stay exact', () {
      final dob = DateTime(2024, 2, 29);
      expect(
        ageAtEvent(_dobProfile('p', dob), DateTime(2025, 2, 28)),
        'Age 11 months',
      );
      expect(ageAtEvent(_dobProfile('p', dob), DateTime(2028, 2, 29)), 'Age 4');
    });

    test('pre-birth and missing events stay unknown, never negative', () {
      final profile = _dobProfile('p', DateTime(2024, 10, 1));
      expect(ageAtEvent(profile, DateTime(2020, 5, 1)), 'Age at event unknown');
      expect(ageAtEvent(profile, null), 'Age at event unknown');
    });
  });

  group('DOB validation', () {
    test('future rejected, past and absent accepted', () {
      expect(
        validateDateOfBirth(DateTime.now().add(const Duration(days: 1))),
        isNotNull,
      );
      expect(validateDateOfBirth(DateTime(2024, 1, 2)), isNull);
      expect(validateDateOfBirth(null), isNull);
    });
  });

  group('legacy age compatibility', () {
    test('old constructor form and About-age labels keep working', () {
      // Non-const: DateTime args are runtime values, not constants.
      final legacy = Profile(
        id: 'p',
        name: 'Synthetic Child',
        age: 2,
        ageRecordedAt: DateTime.utc(2026, 10, 12),
        history: 'h',
      );
      expect(legacy.dateOfBirth, isNull);
      expect(ageAtEvent(legacy, DateTime(2026, 3, 14)), 'About age 1');
    });

    test('profile with neither dating method stays unknown', () {
      const bare = Profile(id: 'p', name: 'N', history: 'h');
      expect(ageAtEvent(bare, DateTime(2026, 3, 14)), 'Age at event unknown');
    });

    test('DOB round-trips through JSON without invention', () {
      final profile = _dobProfile('p', DateTime(2023, 4, 5));
      final back = Profile.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(profile.toJson())) as Map,
        ),
      );
      expect(back.dateOfBirth, DateTime(2023, 4, 5));
      expect(back.age, isNull);
      expect(back.ageRecordedAt, isNull);
    });
  });

  group('vault schema migration', () {
    test(
      'schema 1 age-only data decodes with empty sessions, no invented DOB',
      () {
        const schema1 =
            '{"schema":1,"profiles":[{"id":"p1","name":"A","age":2,'
            '"ageRecordedAt":"2026-10-12T00:00:00.000Z","history":"h",'
            '"isChild":true}],"reports":[],"modelType":"gemma4"}';
        final data = VaultData.decode(schema1);
        expect(data.profiles.single.age, 2);
        expect(data.profiles.single.dateOfBirth, isNull);
        expect(data.sessions, isEmpty);
        expect(data.memories, isEmpty);
        expect(data.activeProfileId, isNull);
        expect(data.activeSessionId, isNull);
      },
    );

    test('schema 2 round-trips sessions, memories, and active ids', () {
      final session = ConversationSession(
        id: 's1',
        profileId: 'p1',
        title: 'Fever questions',
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 2),
      );
      final memory = ConversationMemory(
        id: 's1-memory',
        profileId: 'p1',
        sessionId: 's1',
        text: 'Asked about paracetamol fever care.',
        updatedAt: DateTime.utc(2026, 10, 2),
      );
      final data = VaultData(
        sessions: [session],
        memories: [memory],
        activeProfileId: 'p1',
        activeSessionId: 's1',
        activeSessionByProfile: const {'p1': 's1', 'p2': 's9'},
      );
      final back = VaultData.decode(jsonEncode(data.toJson()));
      expect(back.sessions.single.profileId, 'p1');
      expect(back.sessions.single.title, 'Fever questions');
      expect(back.memories.single.sessionId, 's1');
      expect(back.memories.single.profileId, 'p1');
      expect(back.activeProfileId, 'p1');
      expect(back.activeSessionId, 's1');
      expect(back.activeSessionByProfile, {'p1': 's1', 'p2': 's9'});
    });

    test('missing map key decodes empty; future DOB in JSON is rejected', () {
      final data = VaultData.decode('{"schema":2,"profiles":[],"reports":[]}');
      expect(data.activeSessionByProfile, isEmpty);
      expect(
        () => Profile.fromJson({
          'id': 'p',
          'name': 'N',
          'history': 'h',
          'dateOfBirth': DateTime.now()
              .add(const Duration(days: 30))
              .toIso8601String(),
        }),
        throwsFormatException,
      );
    });

    test('memory retrieval stays profile-scoped with session exclusion', () {
      final mine = ConversationMemory(
        id: 'm1',
        profileId: 'p1',
        sessionId: 's1',
        text: 'Asked about paracetamol fever care.',
        updatedAt: DateTime.utc(2026, 10, 2),
      );
      final otherProfile = ConversationMemory(
        id: 'm2',
        profileId: 'p2',
        sessionId: 's9',
        text: 'Asked about paracetamol fever care.',
        updatedAt: DateTime.utc(2026, 10, 3),
      );
      final hits = retrieveConversationMemories(
        profileId: 'p1',
        memories: [mine, otherProfile],
        query: 'paracetamol fever',
      );
      expect(hits.map((m) => m.id), ['m1']);
      expect(
        retrieveConversationMemories(
          profileId: 'p1',
          memories: [mine],
          query: 'paracetamol fever',
          excludeSessionId: 's1',
        ),
        isEmpty,
      );
    });

    test('copy clears active ids without dropping stored sessions', () {
      final data = VaultData(
        sessions: [
          ConversationSession(
            id: 's1',
            profileId: 'p1',
            title: 'T',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
        activeProfileId: 'p1',
        activeSessionId: 's1',
      );
      final cleared = data.copy(
        clearActiveSession: true,
        clearActiveProfile: true,
      );
      expect(cleared.activeSessionId, isNull);
      expect(cleared.activeProfileId, isNull);
      expect(cleared.sessions, hasLength(1));
    });
  });
}
