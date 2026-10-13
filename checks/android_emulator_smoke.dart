// Manual debug runtime check on an Android emulator, using synthetic data only.
// Run twice: normal, then --dart-define=AYUMITRA_SMOKE_RESTORE=true.
// This exercises native storage/plugins and real local models, not GUI clicks.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/emulator/emulator_controller.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/notice_registry.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/ui/app.dart';

const _marker = 'AYUMITRA_SYNTHETIC_EMULATOR_SMOKE_V1';
const _restoreOnly = bool.fromEnvironment('AYUMITRA_SMOKE_RESTORE');
const _retryAnswer = bool.fromEnvironment('AYUMITRA_SMOKE_RETRY_ANSWER');
const _memoryCheck = bool.fromEnvironment('AYUMITRA_SMOKE_MEMORY');
const _memoryRestore = bool.fromEnvironment('AYUMITRA_SMOKE_MEMORY_RESTORE');
const _question =
    'What is the hemoglobin value on March 14, 2026? Answer in one sentence with its unit and a source reference.';
const _text =
    'SYNTHETIC REPORT - NOT A REAL PATIENT\n'
    'Report date: 2026-03-14\n'
    'Test | Result | Unit | Reference range\n'
    'Hemoglobin | 11.2 | g/dL | 11.5-15.5\n'
    'White blood cell count | 7.4 | x10^9/L | 4.5-13.5\n';
const _pdf =
    'JVBERi0xLjMKJZOMi54gUmVwb3J0TGFiIEdlbmVyYXRlZCBQREYgZG9jdW1lbnQgKG9wZW5zb3VyY2UpCjEgMCBvYmoKPDwKL0YxIDIgMCBSIC9GMiAzIDAgUgo+PgplbmRvYmoKMiAwIG9iago8PAovQmFzZUZvbnQgL0hlbHZldGljYSAvRW5jb2RpbmcgL1dpbkFuc2lFbmNvZGluZyAvTmFtZSAvRjEgL1N1YnR5cGUgL1R5cGUxIC9UeXBlIC9Gb250Cj4+CmVuZG9iagozIDAgb2JqCjw8Ci9CYXNlRm9udCAvSGVsdmV0aWNhLUJvbGQgL0VuY29kaW5nIC9XaW5BbnNpRW5jb2RpbmcgL05hbWUgL0YyIC9TdWJ0eXBlIC9UeXBlMSAvVHlwZSAvRm9udAo+PgplbmRvYmoKNCAwIG9iago8PAovQ29udGVudHMgOCAwIFIgL01lZGlhQm94IFsgMCAwIDU5NS4yNzU2IDg0MS44ODk4IF0gL1BhcmVudCA3IDAgUiAvUmVzb3VyY2VzIDw8Ci9Gb250IDEgMCBSIC9Qcm9jU2V0IFsgL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSSBdCj4+IC9Sb3RhdGUgMCAvVHJhbnMgPDwKCj4+IAogIC9UeXBlIC9QYWdlCj4+CmVuZG9iago1IDAgb2JqCjw8Ci9QYWdlTW9kZSAvVXNlTm9uZSAvUGFnZXMgNyAwIFIgL1R5cGUgL0NhdGFsb2cKPj4KZW5kb2JqCjYgMCBvYmoKPDwKL0F1dGhvciAoYW5vbnltb3VzKSAvQ3JlYXRpb25EYXRlIChEOjIwMjYxMDEyMTYxMDA2KzA1JzAwJykgL0NyZWF0b3IgKGFub255bW91cykgL0tleXdvcmRzICgpIC9Nb2REYXRlIChEOjIwMjYxMDEyMTYxMDA2KzA1JzAwJykgL1Byb2R1Y2VyIChSZXBvcnRMYWIgUERGIExpYnJhcnkgLSBcKG9wZW5zb3VyY2VcKSkgCiAgL1N1YmplY3QgKHVuc3BlY2lmaWVkKSAvVGl0bGUgKHVudGl0bGVkKSAvVHJhcHBlZCAvRmFsc2UKPj4KZW5kb2JqCjcgMCBvYmoKPDwKL0NvdW50IDEgL0tpZHMgWyA0IDAgUiBdIC9UeXBlIC9QYWdlcwo+PgplbmRvYmoKOCAwIG9iago8PAovRmlsdGVyIFsgL0FTQ0lJODVEZWNvZGUgL0ZsYXRlRGVjb2RlIF0gL0xlbmd0aCA2MTEKPj4Kc3RyZWFtCkdhc2JXRGY9PmAmQjxXJTtyI1E+Pilfa0Q6VTUxJFVdTiFsTTdUMCs8S2c+P1lZNSdJQF1KdGNIU0pxTy5RKTpDakYkT3NyJkZHPCFRQmlpcEw0O0ZDTEQsJUo4bTdoMEw1aS8kclYwLm8sSlY9cTJrKUVTb2s9PExsLUslNWZZU2MyOHVDQlw6L1trUjtsc2cjbT1ZYSM2WF8sbGo7XypdbihHaWJbP20iLTQsLGs2U2xbWUU1LmxDRE9aOSxiQS9OLF5NXk5nMmRsVzhxL1MpVUdUaHI0VCpgbyg6YF8pPmo6Mj4+W2dDOkdsWG9KQHE3PE1qUS04TFZSbkdnPmNYUjtXUGgrWD1eTWMmQjxTTUcyM2M/ZEZBMFZyTjo+SUAsWmBhJWhnTzciXDhYLCoiTzNSNTM3Li9bcFtycDQmRTghUz4kSVp0ZiZNaSdpS1QmZHI6YCQkNyJaLVhUa2MlUTosPipePWY6KVhnZiZDVzYvKDAidCthJSNdZmVUT2AkP15HdWdWdU48ay1pc25JZUw6Uz5hSHBLVCErS2hEZWhYcWljND1RaXRqWm9OKnVoZT06VTVUT1Eob3RCSCxZcWpXUk00XiY8ZWozPVVzbFU7UEdlaUYlRkdkNSJpaFBAREh1QjonVWw7SHFhdCdVU0cpYXM3RSFtOjQ5ZS1ISj9bQVhgTlYnLHBDTjwrYS9ibEtoI1U6MVA/JFNtRyM8RT5eb0VZMV1dRmZbOG06W1ZaSzcoY01FLGxlNkx1XF1fYilISy9DRU1lW2YlND41UWtLZnFATz5lTDcuPFhfPX4+ZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgOQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwNjEgMDAwMDAgbiAKMDAwMDAwMDEwMiAwMDAwMCBuIAowMDAwMDAwMjA5IDAwMDAwIG4gCjAwMDAwMDAzMjEgMDAwMDAgbiAKMDAwMDAwMDUyNCAwMDAwMCBuIAowMDAwMDAwNTkyIDAwMDAwIG4gCjAwMDAwMDA4NTMgMDAwMDAgbiAKMDAwMDAwMDkxMiAwMDAwMCBuIAp0cmFpbGVyCjw8Ci9JRCAKWzxlZjY2ZThhNmUyODA2OGUxNzdjMmJlZTgzNWFjZGJjNz48ZWY2NmU4YTZlMjgwNjhlMTc3YzJiZWU4MzVhY2RiYzc+XQolIFJlcG9ydExhYiBnZW5lcmF0ZWQgUERGIGRvY3VtZW50IC0tIGRpZ2VzdCAob3BlbnNvdXJjZSkKCi9JbmZvIDYgMCBSCi9Sb290IDUgMCBSCi9TaXplIDkKPj4Kc3RhcnR4cmVmCjE2MTMKJSVFT0YK';

class _SmokeCheckFailure implements Exception {
  const _SmokeCheckFailure(this.check);
  final String check;
}

void _require(bool condition, String check) {
  if (!condition) throw _SmokeCheckFailure(check);
  debugPrint('AYUMITRA_SMOKE PASS $check');
}

Future<void> _checkOriginal(
  EmulatorAppController c,
  Report report,
  List<int> expected,
) async {
  final original = await c.vault.readOriginal(report, report.profileId);
  _require(
    sha256.convert(original) == sha256.convert(expected),
    'original byte-for-byte restored (${report.type})',
  );
  final encrypted = await File(
    '${c.vault.directory.path}/originals/${report.profileId}/${report.id}.enc',
  ).readAsBytes();
  _require(
    sha256.convert(encrypted) != sha256.convert(expected) &&
        !latin1.decode(encrypted).contains('Hemoglobin'),
    'original stored as ciphertext (${report.type})',
  );
  var denied = false;
  try {
    await c.vault.readOriginal(report, 'different-profile');
  } on StateError {
    denied = true;
  }
  _require(denied, 'cross-profile original read denied');
}

Future<void> _exercise(EmulatorAppController c) async {
  _require(c.loaded, 'Android encrypted vault opened');
  final intelligence = c.intelligence as WebIntelligence;
  _require(intelligence.available, 'installed local Gemma 4 verified');
  _require(intelligence.visionAvailable, 'local Gemma 4 vision verified');
  _require(c.embeddings.available, 'installed local EmbeddingGemma 2 verified');
  // No public searches in this synthetic fixture check.
  c.webSearch.apiKey = null;
  if (_memoryCheck || _memoryRestore) {
    final owner = c.data.profiles.lastWhere((p) => p.history == _marker);
    await c.selectProfile(owner.id);
    final originals = c.reports.map((r) => r.digest).toList();
    if (!_memoryRestore) {
      await c.ask('My hemoglobin is 13 g/dL.');
      final update = c.messages.last;
      _require(
        !update.isUser &&
            update.text.contains('13') &&
            update.text.contains('[conversation:${c.activeSessionId}]'),
        'real Gemma acknowledges user update with conversation provenance',
      );
      _require(
        update.text.toLowerCase().contains('report') &&
            update.text.contains('?'),
        'uncorroborated user update asks for a report',
      );
      _require(
        update.hits.every(
          (h) => !h.line.text.contains('11.2') || update.text.contains('11.2'),
        ),
        'old report cannot corroborate the new value silently',
      );
    } else {
      _require(
        c.data.memories.any(
          (m) => m.profileId == owner.id && m.text.contains('13 g/dL'),
        ),
        'user observation restored from encrypted memory',
      );
    }
    final reportedAt = c.activeSession!.turns
        .lastWhere(
          (t) => t.role == 'user' && t.text == 'My hemoglobin is 13 g/dL.',
        )
        .createdAt;
    await c.ask(
      'What is my latest hemoglobin value, and when did I report it?',
    );
    final recalled = c.messages.last;
    _require(
      !recalled.isUser &&
          recalled.text.contains('13') &&
          recalled.text.contains('[conversation:${c.activeSessionId}]'),
      'real Gemma recalls the current user-reported value',
    );
    _require(
      recalled.text.contains(reportedAt.toIso8601String().split('T').first),
      'real Gemma retains the observation provided date',
    );
    _require(
      c.reports.map((r) => r.digest).join() == originals.join() &&
          c.reports.every((r) => r.facts.any((f) => f.value == '11.2')),
      'chat update preserves original dated report values',
    );
    _require(
      c.data.memories.any(
        (m) => m.profileId == owner.id && m.text.contains('13 g/dL'),
      ),
      'user observation is saved in profile memory',
    );
    final voice = await const MethodChannel(
      'app.ayumitra/voice',
    ).invokeMapMethod<String, dynamic>('capabilities');
    _require(
      voice != null &&
          voice['onDevice'] is bool &&
          voice['available'] is bool &&
          (voice['available'] != true || voice['onDevice'] == true),
      'native voice capability fails closed without on-device support',
    );
    debugPrint(
      'AYUMITRA_SMOKE VOICE available=${voice?['available']} onDevice=${voice?['onDevice']}',
    );
  } else if (!_restoreOnly) {
    if (_retryAnswer) {
      final existing = c.data.profiles.lastWhere((p) => p.history == _marker);
      await c.selectProfile(existing.id);
    } else {
      await c.createProfile(
        'Synthetic Android Child',
        DateTime(2020, 1, 15),
        _marker,
        true,
      );
      _require(c.profile?.history == _marker, 'DOB profile/background created');
      _require(
        c.activeSession?.turns.length == 1 &&
            c.data.memories.any((m) => m.profileId == c.activeProfileId),
        'background seeds session and memory',
      );
      final scratch = Directory(
        '${(await getTemporaryDirectory()).path}/ayumitra-picker',
      );
      await scratch.create(recursive: true);
      final fixtures = <String, List<int>>{
        'synthetic-cbc.txt': utf8.encode(_text),
        'synthetic-cbc.pdf': base64Decode(_pdf),
      };
      for (final entry in fixtures.entries) {
        final picked = File('${scratch.path}/${entry.key}');
        await picked.writeAsBytes(entry.value, flush: true);
        await c.importFile(NativePickedFile(picked.path));
        final report = c.reports.singleWhere((r) => r.name == entry.key);
        _require(
          report.lines.any((l) => l.text.contains('11.2')),
          'native document parsed (${report.type})',
        );
        _require(
          report.vectors.isNotEmpty &&
              report.vectors.values.every((v) => v.length == 768),
          'real EG2 vectors indexed (${report.type})',
        );
        _require(
          report.facts.any((f) => f.value == '11.2'),
          'real Gemma extraction validated (${report.type})',
        );
        _require(
          report.summaryMarkdown?.isNotEmpty == true,
          'real Gemma Markdown summary accepted (${report.type})',
        );
        await _checkOriginal(c, report, entry.value);
        _require(!await picked.exists(), 'temporary picker plaintext removed');
      }
    }
    await c.ask(_question);
    final answer = c.messages.last;
    _require(
      !answer.isUser &&
          answer.text.contains('11.2') &&
          answer.text.contains('g/dL'),
      'real Gemma answer gives fixture value and unit',
    );
    _require(
      answer.hits.isNotEmpty &&
          answer.hits.every(
            (h) =>
                h.report.profileId == c.profile!.id &&
                answer.text.contains('[${h.citation}]'),
          ),
      'answer references only cited owned files',
    );
    final owner = c.profile!.id;
    await c.createProfile(
      'Synthetic Android Other Profile',
      DateTime(1990, 1, 1),
      '',
      false,
    );
    _require(
      c.reports.isEmpty && c.messages.isEmpty,
      'second profile has isolated files and sessions',
    );
    await c.selectProfile(owner);
  } else {
    final owner = c.data.profiles.lastWhere((p) => p.history == _marker);
    await c.selectProfile(owner.id);
    _require(
      c.reports.length == 2 &&
          c.messages.any(
            (m) =>
                !m.isUser &&
                m.text.contains('11.2') &&
                m.text.contains('g/dL') &&
                m.hits.isNotEmpty,
          ),
      'profiles files and answer survive process restart',
    );
    _require(
      c.data.memories.any((m) => m.profileId == owner.id),
      'session memory survives process restart',
    );
    for (final r in c.reports) {
      await _checkOriginal(
        c,
        r,
        r.name.endsWith('.pdf') ? base64Decode(_pdf) : utf8.encode(_text),
      );
      _require(
        r.vectors.isNotEmpty && r.summaryMarkdown?.isNotEmpty == true,
        'indexed report and summary survive restart',
      );
    }
  }
  final index = await File('${c.vault.directory.path}/index.enc').readAsBytes();
  _require(
    !latin1.decode(index).contains(_marker) &&
        !latin1.decode(index).contains('11.2'),
    'health-bearing index stored as ciphertext',
  );
}

Future<void> main() async {
  requireEmulatorDebugBuild(kDebugMode);
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';
  await initializeDateFormatting('en_US');
  registerAyumitraNotices();
  FlutterError.onError = (d) =>
      debugPrint('AYUMITRA_SMOKE UI_ERROR ${d.exception.runtimeType}');
  final c = EmulatorAppController();
  runApp(AyumitraApp(controller: c));
  var stage = 'initialize';
  try {
    await pdfrxFlutterInitialize();
    await c.initialize();
    stage = 'exercise';
    await _exercise(c);
    debugPrint('AYUMITRA_SMOKE ALL_PASS restore=$_restoreOnly');
  } catch (error) {
    // Only these assertion messages are fixture metadata; never print model/error bodies.
    debugPrint('AYUMITRA_SMOKE FAILED stage=$stage type=${error.runtimeType}');
    if (error is _SmokeCheckFailure) {
      debugPrint('AYUMITRA_SMOKE CHECK ${error.check}');
    }
  }
}
