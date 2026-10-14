import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/domain/vitals.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnavailableAssistant extends LocalIntelligence {
  int generationCalls = 0;

  @override
  bool get available => false;

  @override
  Future<String> generate(String instruction, String input) async {
    generationCalls++;
    throw StateError('These tests must not require a model.');
  }
}

class _UnavailableVectors extends LocalEmbeddings {
  @override
  bool get available => false;
}

class _RejectingSaveVault extends EncryptedVault {
  _RejectingSaveVault({required super.directory, required super.key});

  @override
  Future<void> save(VaultData data) async {
    throw const FileSystemException('Synthetic persistence failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final preview in [false, true]) {
    group(preview ? 'browser chat vitals' : 'native persisted chat vitals', () {
      late AppController c;
      late _UnavailableAssistant assistant;
      Directory? directory;

      setUp(() async {
        assistant = _UnavailableAssistant();
        final embeddings = _UnavailableVectors();
        c = preview
            ? DemoController(intelligence: assistant, embeddings: embeddings)
            : AppController(intelligence: assistant, embeddings: embeddings);
        if (!preview) {
          directory = await Directory.systemTemp.createTemp(
            'ayumitra-chat-vitals-',
          );
          c.vault = EncryptedVault(
            directory: directory!,
            key: await AesGcm.with256bits().newSecretKey(),
          );
        }
        c
          ..loaded = true
          ..activeProfileId = 'alice'
          ..data = VaultData(
            activeProfileId: 'alice',
            profiles: [
              Profile(
                id: 'alice',
                name: 'Synthetic Alice',
                history: '',
                dateOfBirth: DateTime(2000),
              ),
              Profile(
                id: 'bob',
                name: 'Synthetic Bob',
                history: '',
                dateOfBirth: DateTime(2001),
              ),
            ],
          );
      });

      tearDown(() async {
        c.dispose();
        if (directory != null) {
          await directory!.delete(recursive: true);
          directory = null;
        }
      });

      test(
        'a chat reading is saved with its original turn timestamp without a model',
        () async {
          await c.ask('My pulse is 72 bpm');
          expect(c.failure, isNull);
          expect(assistant.generationCalls, 0);
          final userTurn = c.activeSession!.turns.firstWhere(
            (turn) => turn.role == 'user',
          );
          final reading = c.vitals.single;
          expect(reading.id, 'chat:${userTurn.id}:pulse');
          expect(reading.profileId, 'alice');
          expect(reading.kind, VitalKind.pulse);
          expect(reading.value, 72);
          expect(reading.unit, 'bpm');
          expect(reading.source, 'user');
          expect(reading.sourceLineId, isNull);
          expect(reading.measuredAt, userTurn.createdAt);
          expect(reading.note, contains(userTurn.id));
          if (!preview) {
            final saved = await c.vault.read();
            expect(saved.vitals.single.toJson(), reading.toJson());
            expect(
              saved.sessions.single.turns
                  .firstWhere((turn) => turn.role == 'user')
                  .id,
              userTurn.id,
            );
          }
        },
      );

      test(
        'an explicitly reported event date overrides the new message timestamp',
        () async {
          await c.ask('My blood pressure was 120/80 mmHg on March 14, 2024');
          expect(c.failure, isNull);
          final reading = c.vitals.single;
          expect(reading.kind, VitalKind.bloodPressure);
          expect(reading.value, 120);
          expect(reading.secondaryValue, 80);
          expect(reading.measuredAt, DateTime(2024, 3, 14));
          final userTurn = c.activeSession!.turns.firstWhere(
            (turn) => turn.role == 'user',
          );
          expect(reading.id, 'chat:${userTurn.id}:bloodPressure');
          expect(reading.measuredAt, isNot(userTurn.createdAt));
          if (!preview) {
            expect(
              (await c.vault.read()).vitals.single.measuredAt,
              reading.measuredAt,
            );
          }
        },
      );

      test(
        'questions, fabricated drafts and quoted readings do not become tracked measurements',
        () async {
          for (final question in [
            'Was my pulse 72 bpm?',
            'Should blood pressure be 120/80 mmHg?',
            'Create a hypothetical report with SpO2 98%',
            'Someone wrote "Temperature 37 °C"',
          ]) {
            await c.ask(question);
            expect(c.failure, isNull, reason: question);
            expect(c.data.vitals, isEmpty, reason: question);
          }
          expect(assistant.generationCalls, 0);
          if (!preview) expect((await c.vault.read()).vitals, isEmpty);
        },
      );

      test(
        'a reported measurement survives its following question without recording the hypothetical value',
        () async {
          await c.ask('My pulse was 72 bpm; should temperature be 37 °C?');
          expect(c.failure, isNull);
          expect(c.vitals, hasLength(1));
          expect(c.vitals.single.kind, VitalKind.pulse);
          expect(c.vitals.single.value, 72);
        },
      );

      test(
        'deleting a conversation removes its derived readings while preserving manual and other owners',
        () async {
          await c.ask('My pulse is 72 bpm');
          final firstSession = c.activeSessionId!;
          final firstReading = c.vitals.single.id;
          await c.recordVital(VitalKind.spo2, 98, note: 'ALICE_MANUAL_READING');
          final manual = c.vitals
              .firstWhere((entry) => entry.note == 'ALICE_MANUAL_READING')
              .id;
          await c.newConversation();
          await c.ask('My temperature is 37 °C');
          final secondSession = c.activeSessionId!;
          final secondReading = c.vitals
              .firstWhere((entry) => entry.kind == VitalKind.temperature)
              .id;
          expect(secondSession, isNot(firstSession));

          await c.selectProfile('bob');
          await c.ask('My pulse is 80 bpm');
          final bobSession = c.activeSessionId!;
          final bobChat = c.vitals.single.id;
          await c.recordVital(
            VitalKind.temperature,
            38,
            note: 'BOB_MANUAL_READING',
          );
          final bobManual = c.vitals
              .firstWhere((entry) => entry.note == 'BOB_MANUAL_READING')
              .id;
          await c.selectProfile('alice');

          await c.deleteConversation(firstSession);
          expect(c.failure, isNull);
          expect(c.activeSessionId, secondSession);
          expect(
            c.data.vitals.map((entry) => entry.id),
            isNot(contains(firstReading)),
          );
          expect(
            c.data.vitals.map((entry) => entry.id),
            containsAll([manual, secondReading, bobChat, bobManual]),
          );
          expect(
            c.data.sessions.any((session) => session.id == firstSession),
            isFalse,
          );
          expect(
            c.data.memories.any((memory) => memory.sessionId == firstSession),
            isFalse,
          );

          // A different owner's conversation cannot be erased from Alice's profile.
          await c.deleteConversation(bobSession);
          expect(
            c.data.sessions.any((session) => session.id == bobSession),
            isTrue,
          );
          expect(
            c.data.vitals.map((entry) => entry.id),
            containsAll([bobChat, bobManual]),
          );
          await c.deleteConversation(secondSession);
          expect(
            c.data.vitals.map((entry) => entry.id),
            unorderedEquals([manual, bobChat, bobManual]),
          );
          if (!preview) {
            final restored = await c.vault.read();
            expect(
              restored.vitals.map((entry) => entry.id),
              unorderedEquals([manual, bobChat, bobManual]),
            );
            expect(restored.sessions.map((session) => session.id), [
              bobSession,
            ]);
          }
        },
      );

      test(
        'invalid manual readings throw without a success state or stored measurement',
        () async {
          await expectLater(
            c.recordVital(VitalKind.spo2, 101),
            throwsA(isA<FormatException>()),
          );
          await expectLater(
            c.recordVital(VitalKind.bloodPressure, 120),
            throwsA(isA<FormatException>()),
          );
          expect(c.data.vitals, isEmpty);
          expect(c.busy, isFalse);
        },
      );

      if (!preview) {
        test(
          'manual persistence failure throws and preserves the prior encrypted snapshot',
          () async {
            await c.vault.save(c.data);
            c.vault = _RejectingSaveVault(
              directory: c.vault.directory,
              key: c.vault.key,
            );
            await expectLater(
              c.recordVital(VitalKind.pulse, 72),
              throwsA(isA<StateError>()),
            );
            expect(c.failure, isNotNull);
            expect(c.busy, isFalse);
            expect(c.data.vitals, isEmpty);
            final saved = await c.vault.read();
            expect(saved.vitals, isEmpty);
            expect(saved.profiles.map((profile) => profile.id), [
              'alice',
              'bob',
            ]);
          },
        );
      }
    });
  }
}
