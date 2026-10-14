// Debug-only live comparison over an isolated synthetic profile. The human
// explicitly authorizes these two questions to use the already-configured
// cloud provider; this never accepts a disclosure or enables cloud mode.
// Install with adb install -r only; never uninstall to repair an install.
// No answers, prompts, patient data, provider credentials or private names are
// printed. Both answer sets remain in the existing encrypted local vault.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/notice_registry.dart';
import 'package:ayumitra/ui/app.dart';

const _localOnly = bool.fromEnvironment('AYUMITRA_QUALITY_LOCAL_ONLY');
const _marker = 'AYUMITRA_SYNTHETIC_QUALITY_COMPARE_V1';
const _profileName = 'Synthetic Quality Comparison';
const _history =
    '$_marker\n'
    'SYNTHETIC TEST ONLY - NOT A REAL PATIENT.\n'
    'I reported a pulse of 72 bpm on 2026-03-13.\n'
    'I reported a temperature of 37.0 °C on 2026-03-14.\n'
    'These two observations are user-reported and unverified.';
const _seededHistory =
    'Background I provided when creating this profile:\n$_history';
const _fixture =
    'SYNTHETIC REPORT - NOT A REAL PATIENT\n'
    'Report date: 2026-03-14\n'
    'Test | Result | Unit | Reference range\n'
    'Hemoglobin | 11.2 | g/dL | 11.5-15.5\n'
    'White blood cell count | 7.4 | x10^9/L | 4.5-13.5\n';
const _questions = [
  'What hemoglobin value appears on the March 14, 2026 report? '
      'Answer directly with the exact value, original unit, and a source reference.',
  'Craft a concise health report from this profile’s saved report and history. '
      'Preserve the dates and distinguish report-confirmed findings from the '
      'user-reported pulse and temperature, which are unverified. Cite the sources.',
];

class _ComparisonFailure implements Exception {
  const _ComparisonFailure(this.check);
  final String check;
}

void _require(bool condition, String check) {
  if (!condition) throw _ComparisonFailure(check);
  debugPrint('AYUMITRA_QUALITY PASS $check');
}

/// Production models, parser, vault, WebSearch and provider transport. Only
/// unrelated automatic jobs and lost-camera recovery are paused in this debug
/// harness, so initialization cannot process another person's records.
class _ComparisonController extends AppController {
  bool skippedCameraRecovery = false;
  @override
  bool get automaticProcessingChecksEnabled => false;

  @override
  Future<void> recoverCameraCapture() async {
    skippedCameraRecovery = true;
  }
}

void _showProgress() => runApp(
  const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text(
                  'Comparing two synthetic questions on the local and selected cloud model. '
                  'Your saved records and settings are preserved. Ayumitra will reopen when finished.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void _validateOwnedInputs(AppController c, String ownerId) {
  _require(c.profile?.id == ownerId, 'synthetic owner still selected');
  _require(
    c.profile!.name == _profileName && c.profile!.history == _history,
    'synthetic identity and history unchanged',
  );
  final allowedUserText = {_seededHistory, ..._questions};
  _require(
    c.data.sessions
        .where((session) => session.profileId == ownerId)
        .every(
          (session) => session.turns
              .where((turn) => turn.role == 'user')
              .every((turn) => allowedUserText.contains(turn.text)),
        ),
    'all synthetic user turns belong to fixed comparison inputs',
  );
  _require(
    c.data.vitals.every((entry) => entry.profileId != ownerId),
    'no extra manually supplied readings in synthetic profile',
  );
  final expectedDigest = sha256.convert(utf8.encode(_fixture)).toString();
  _require(
    c.data.reports
        .where((report) => report.profileId == ownerId)
        .every(
          (report) =>
              report.digest == expectedDigest &&
              report.name == 'Synthetic blood report.txt' &&
              report.extension == 'txt' &&
              report.lines.every(
                (line) =>
                    line.text.trim().isNotEmpty &&
                    _fixture.contains(line.text.trim()),
              ),
        ),
    'all synthetic report rows originate in fixed fixture',
  );
}

void _validatePreview(
  AppController c,
  FrontierRequest request,
  String ownerId,
) {
  _validateOwnedInputs(c, ownerId);
  _require(
    request.profileId == ownerId &&
        request.hits.every((hit) => hit.report.profileId == ownerId),
    'cloud preview sources owned by synthetic profile',
  );
  final payload = jsonDecode(request.previewText) as Map;
  _require(
    (payload['userHistory'] as Map?)?['text'] == _history &&
        ((payload['userRecordedVitals'] as Map?)?['text'] ?? '') == '',
    'cloud preview contains fixed synthetic history only',
  );
  // Payload rows carry short per-call aliases; resolve through the request's
  // canonical order before checking against synthetic sources.
  final order = List<String>.from(request.canonicalOrder);
  String resolve(String ref) {
    final alias = RegExp(r'^S(\d+)$').firstMatch(ref);
    if (alias == null) return ref;
    final index = int.parse(alias.group(1)!) - 1;
    if (index < 0 || index >= order.length) return ref;
    return order[index];
  }

  final allowedReferences = {
    'user-history',
    ...c.data.reports
        .where((report) => report.profileId == ownerId)
        .expand(
          (report) => report.lines.map((line) => '${report.id}/${line.id}'),
        ),
    ...c.data.sessions
        .where((session) => session.profileId == ownerId)
        .map((session) => 'conversation:${session.id}'),
  };
  final evidence = payload['evidence'];
  _require(
    evidence is List &&
        evidence.every(
          (row) =>
              row is Map &&
              allowedReferences.contains(resolve(row['sourceId'] as String)),
        ) &&
        request.allowedReferences.every(allowedReferences.contains),
    'cloud reference allowlist contains synthetic sources only',
  );
  final folded = request.previewText.toLowerCase();
  _require(
    c.data.profiles.where((profile) => profile.id != ownerId).every((profile) {
      final name = profile.name.trim().toLowerCase();
      final history = profile.history.trim().toLowerCase();
      return !folded.contains(profile.id.toLowerCase()) &&
          (name.length < 3 || !folded.contains(name)) &&
          (history.isEmpty || !folded.contains(history));
    }),
    'cloud preview excludes other profile names identifiers and histories',
  );
}

class _AnswerResult {
  const _AnswerResult(this.answer, this.flags);
  final String? answer;
  final Map<String, Object> flags;
}

_AnswerResult _diagnose({
  required String lane,
  required int question,
  required AppController c,
  required int assistantCountBefore,
  required int elapsedMs,
}) {
  final turns = c.activeSession!.turns
      .where((turn) => turn.role == 'assistant')
      .toList();
  final generated = turns.length > assistantCountBefore;
  final text = generated ? turns.last.text : '';
  final expectedValue = RegExp(r'(?<![\d.])11\.2(?![\d.])').hasMatch(text);
  final expectedUnit = RegExp(
    r'\bg\s*/\s*dL\b',
    caseSensitive: false,
  ).hasMatch(text);
  final citationCount = RegExp(r'\[[^\]\n]+\]').allMatches(text).length;
  final userReported = RegExp(
    r'user[- ]reported|unverified|self[- ]reported',
    caseSensitive: false,
  ).hasMatch(text);
  final hasPulse = RegExp(
    r'(?<![\d.])72\s*bpm\b',
    caseSensitive: false,
  ).hasMatch(text);
  final hasTemperature = RegExp(
    r'(?<![\d.])37(?:\.0)?\s*°?\s*C\b',
    caseSensitive: false,
  ).hasMatch(text);
  final flags = <String, Object>{
    'generated': generated,
    'failed': c.failure != null,
    'expectedValue': expectedValue,
    'expectedUnit': expectedUnit,
    'citationsCount': citationCount,
    'userReported': userReported,
    'hasPulse': hasPulse,
    'hasTemperature': hasTemperature,
  };
  debugPrint(
    'AYUMITRA_QUALITY ANSWER lane=$lane question=$question '
    'generated=$generated failed=${c.failure != null} ms=$elapsedMs '
    'expectedValue=$expectedValue expectedUnit=$expectedUnit '
    'citationsCount=$citationCount userReported=$userReported '
    'hasPulse=$hasPulse hasTemperature=$hasTemperature',
  );
  return _AnswerResult(generated ? text : null, flags);
}

Future<void> main() async {
  if (!kDebugMode || !Platform.isAndroid) {
    throw UnsupportedError('The synthetic comparison requires debug Android.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';
  await initializeDateFormatting('en_US');
  registerAyumitraNotices();
  FlutterError.onError = (details) => debugPrint(
    'AYUMITRA_QUALITY UI_ERROR type=${details.exception.runtimeType}',
  );
  _showProgress();
  final c = _ComparisonController();
  String? originalProfileId;
  String? originalSessionId;
  String? originalSearchKey;
  var capturedSearchSetting = false;
  var stage = 'initialize';
  final comparisonRows = [
    for (final question in _questions)
      <String, Object?>{
        'question': question,
        'localAnswer': null,
        'cloudAnswer': null,
        'elapsedMs': <String, int>{},
        'flags': <String, Object>{},
      },
  ];
  Future<void> saveSyntheticResult(
    String ownerId,
    int question,
    String lane,
    _AnswerResult result,
    int elapsedMs,
  ) async {
    _validateOwnedInputs(c, ownerId);
    _require(
      c.activeSession?.profileId == ownerId &&
          c.activeSession!.turns
                  .where((turn) => turn.role == 'user')
                  .lastOrNull
                  ?.text ==
              _questions[question],
      'artifact contains only fixed synthetic question and owned answer',
    );
    final row = comparisonRows[question];
    row['${lane}Answer'] = result.answer;
    (row['elapsedMs'] as Map<String, int>)[lane] = elapsedMs;
    (row['flags'] as Map<String, Object>)[lane] = result.flags;
    final support = await getApplicationSupportDirectory();
    final output = File(
      '${support.path}/${_localOnly ? 'ayumitra-synthetic-quality-local-recheck.json' : 'ayumitra-synthetic-quality-comparison.json'}',
    );
    final staging = File('${output.path}.new');
    await staging.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'syntheticOnly': true,
        'localModel': 'Gemma 4',
        'embeddingModel': 'EmbeddingGemma 2',
        'cloudProvider': c.frontierProvider,
        'cloudModel': c.frontierModel,
        'questions': comparisonRows,
      }),
      flush: true,
    );
    await staging.rename(output.path);
    debugPrint('AYUMITRA_QUALITY ARTIFACT_SAVED syntheticOnly=true');
  }

  try {
    await pdfrxFlutterInitialize();
    await c.initialize();
    _require(c.loaded, 'encrypted production controller initialized');
    originalProfileId = c.activeProfileId;
    originalSessionId = c.activeSessionId;
    _require(!c.skippedCameraRecovery, 'no unfinished user camera capture');
    debugPrint(
      'AYUMITRA_QUALITY CONFIG '
      'keyConfigured=${c.frontierAvailable} '
      'disclosureAccepted=${c.frontierDisclosureAccepted} '
      'cloudModeEnabled=${c.useFrontierForChat}',
    );
    if (!_localOnly &&
        (!c.frontierAvailable ||
            !c.frontierDisclosureAccepted ||
            !c.useFrontierForChat)) {
      debugPrint('AYUMITRA_QUALITY STOP cloud_configuration_not_enabled');
      return;
    }
    // Pause public search in memory only. No secure-storage write or key
    // deletion occurs; restore before the interactive app is shown again.
    originalSearchKey = c.webSearch.apiKey;
    capturedSearchSetting = true;
    c.webSearch.apiKey = null;
    stage = 'synthetic_profile';
    final candidates = c.data.profiles
        .where((profile) => profile.history.contains(_marker))
        .toList();
    _require(candidates.length <= 1, 'at most one comparison profile');
    if (candidates.isEmpty) {
      await c.createProfile(
        _profileName,
        DateTime(2020, 1, 15),
        _history,
        true,
      );
    } else {
      await c.selectProfile(candidates.single.id);
    }
    _require(
      c.failure == null && c.profile != null,
      'synthetic profile selected',
    );
    final ownerId = c.profile!.id;
    _validateOwnedInputs(c, ownerId);
    stage = 'models';
    await c.ensureAutomaticModels();
    _require(
      c.intelligence.available &&
          c.embeddings.available &&
          c.modelSetupProgress?.state == 'ready',
      'native fixed model pair ready',
    );
    stage = 'synthetic_report';
    final expectedBytes = Uint8List.fromList(utf8.encode(_fixture));
    final digest = sha256.convert(expectedBytes).toString();
    final existing = c.data.reports
        .where(
          (report) => report.profileId == ownerId && report.digest == digest,
        )
        .toList();
    _require(existing.length <= 1, 'at most one fixed comparison report');
    if (existing.isEmpty) {
      await c.importSample(expectedBytes);
    }
    final report = c.data.reports
        .where(
          (report) => report.profileId == ownerId && report.digest == digest,
        )
        .single;
    _require(
      report.status == ReportStatus.ready &&
          report.lines.isNotEmpty &&
          report.eventDate == DateTime.utc(2026, 3, 14) &&
          !report.dateIsFallback &&
          report.vectors.length == report.lines.length,
      'synthetic original parsed dated and locally indexed',
    );
    final restoredOriginal = await c.vault.readOriginal(report, ownerId);
    _require(
      sha256.convert(restoredOriginal).toString() == digest,
      'encrypted original matches fixed comparison fixture',
    );
    _validateOwnedInputs(c, ownerId);
    stage = 'local_answers';
    await c.newConversation();
    for (var index = 0; index < _questions.length; index++) {
      _validateOwnedInputs(c, ownerId);
      final before = c.activeSession!.turns
          .where((turn) => turn.role == 'assistant')
          .length;
      final timer = Stopwatch()..start();
      await c.ask(_questions[index]);
      final result = _diagnose(
        lane: 'local',
        question: index + 1,
        c: c,
        assistantCountBefore: before,
        elapsedMs: timer.elapsedMilliseconds,
      );
      await saveSyntheticResult(
        ownerId,
        index,
        'local',
        result,
        timer.elapsedMilliseconds,
      );
    }
    if (_localOnly) {
      debugPrint(
        'AYUMITRA_QUALITY FINISHED questions=2 maxCloudRequests=0 localRecheck=true',
      );
      return;
    }
    stage = 'cloud_answers';
    await c.newConversation();
    for (var index = 0; index < _questions.length; index++) {
      _require(
        c.frontierAvailable &&
            c.frontierDisclosureAccepted &&
            c.useFrontierForChat,
        'existing cloud consent remains enabled',
      );
      final request = await c.prepareFrontierRequest(_questions[index]);
      _validatePreview(c, request, ownerId);
      final before = c.activeSession!.turns
          .where((turn) => turn.role == 'assistant')
          .length;
      final timer = Stopwatch()..start();
      await c.sendFrontierRequest(request, maxFormatAttempts: 2);
      final result = _diagnose(
        lane: 'cloud',
        question: index + 1,
        c: c,
        assistantCountBefore: before,
        elapsedMs: timer.elapsedMilliseconds,
      );
      await saveSyntheticResult(
        ownerId,
        index,
        'cloud',
        result,
        timer.elapsedMilliseconds,
      );
    }
    debugPrint('AYUMITRA_QUALITY FINISHED questions=2 maxCloudRequests=4');
  } catch (error) {
    debugPrint(
      'AYUMITRA_QUALITY FAILED stage=$stage type=${error.runtimeType}',
    );
    if (error is _ComparisonFailure) {
      debugPrint('AYUMITRA_QUALITY CHECK ${error.check}');
    }
  } finally {
    if (capturedSearchSetting) c.webSearch.apiKey = originalSearchKey;
    if (c.loaded &&
        originalProfileId != null &&
        c.data.profiles.any((profile) => profile.id == originalProfileId)) {
      await c.selectProfile(originalProfileId);
      if (originalSessionId != null &&
          c.sessions.any((session) => session.id == originalSessionId)) {
        await c.selectConversation(originalSessionId);
      }
    }
    runApp(AyumitraApp(controller: c));
  }
}
