// True on-device core check on a physical Android phone, synthetic data only.
// Debug builds only. Uses the production AppController with LocalIntelligence
// and LocalEmbeddings (no emulator bridge, no loopback, no microphone).
//
// Fixed public weights are prepared by production automatic setup. Android
// DownloadManager owns downloads; verified private caches are reused. Inference
// is the real on-device LocalIntelligence + native EmbeddingGemma 2 engine.
//
// Safe run order, all synthetic. Each mode is baked into its own APK (the
// install step never retries with an uninstall: any install failure aborts
// and storage is fixed by hand, since an uninstall would wipe the vault):
//   flutter build apk --debug --target-platform android-arm64 --target checks/android_device_smoke.dart
//   adb -s <device> install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb -s <device> shell am start -n app.ayumitra.ayumitra/.MainActivity
// Restore/resume/deletion modes rebuild with the matching --dart-define:
//   --dart-define=AYUMITRA_DEVICE_RESTORE=true  (verify only, no mutations)
//   --dart-define=AYUMITRA_DEVICE_RESUME=true   (reuse own profile+report)
//   --dart-define=AYUMITRA_DEVICE_DELETION=true (drop only own conversation)
// Deletion mode removes only the harness's own synthetic conversation; it
// never clears the vault and never touches unknown profiles.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/automatic_models.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/notice_registry.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/ui/app.dart';

const _marker = 'AYUMITRA_SYNTHETIC_DEVICE_CORE_V1';
const _restoreOnly = bool.fromEnvironment('AYUMITRA_DEVICE_RESTORE');
const _resume = bool.fromEnvironment('AYUMITRA_DEVICE_RESUME');
const _deletion = bool.fromEnvironment('AYUMITRA_DEVICE_DELETION');
const _web = bool.fromEnvironment('AYUMITRA_DEVICE_WEB');
const _question =
    'What is the hemoglobin value on March 14, 2026? Answer in one sentence with its unit and a source reference.';
const _update = 'My hemoglobin is 13 g/dL.';
const _recall = 'What is my latest hemoglobin value, and when did I report it?';
const _text =
    'SYNTHETIC REPORT - NOT A REAL PATIENT\n'
    'Report date: 2026-03-14\n'
    'Test | Result | Unit | Reference range\n'
    'Hemoglobin | 11.2 | g/dL | 11.5-15.5\n'
    'White blood cell count | 7.4 | x10^9/L | 4.5-13.5\n';
const _fileName = 'synthetic-device-core.txt';

class _DeviceCheckFailure implements Exception {
  const _DeviceCheckFailure(this.check);
  final String check;
}

void _require(bool condition, String check) {
  if (!condition) throw _DeviceCheckFailure(check);
  debugPrint('AYUMITRA_DEVICE PASS $check');
}

bool _hasReportedValue(String text) => RegExp(
  r'(?<![\d.])13(?:\.0+)?\s*g/dL\b',
  caseSensitive: false,
).hasMatch(text.replaceAll(RegExp(r'[*_`]'), ''));

void _stage(String name) => debugPrint('AYUMITRA_DEVICE STAGE $name');

void _requireDeviceDebugBuild(bool isDebugBuild) {
  if (!isDebugBuild) {
    throw UnsupportedError('The device core check is debug-only.');
  }
}

String? _ownedProfileId(AppController c) {
  for (final p in c.data.profiles) {
    if (p.history == _marker) return p.id;
  }
  return null;
}

Future<void> _checkOriginal(
  AppController c,
  Report report,
  List<int> expected,
) async {
  final original = await c.vault.readOriginal(report, report.profileId);
  _require(
    sha256.convert(original) == sha256.convert(expected),
    'original byte-for-byte restored',
  );
  final encrypted = await File(
    '${c.vault.directory.path}/originals/${report.profileId}/${report.id}.enc',
  ).readAsBytes();
  _require(
    sha256.convert(encrypted) != sha256.convert(expected) &&
        !latin1.decode(encrypted).contains('Hemoglobin'),
    'original stored as ciphertext',
  );
  var denied = false;
  try {
    await c.vault.readOriginal(report, 'different-profile');
  } on StateError {
    denied = true;
  }
  _require(denied, 'cross-profile original read denied');
}

/// Shared report assertions. Returns the measured vector dimension, which is
/// reported, never assumed.
int _checkReportCore(Report report) {
  _require(
    report.lines.any((l) => l.text.contains('11.2')),
    'native document parsed',
  );
  _require(report.vectors.isNotEmpty, 'EG2 vectors indexed');
  var dim = -1;
  for (final v in report.vectors.values) {
    _require(v.isNotEmpty && v.every((x) => x.isFinite), 'EG2 vectors finite');
    if (dim < 0) dim = v.length;
    _require(v.length == dim, 'EG2 vector dimension consistent');
  }
  debugPrint('AYUMITRA_DEVICE VECTOR_DIM $dim');
  _require(
    report.facts.any((f) => f.value == '11.2' && f.unit == 'g/dL'),
    'validated exact 11.2 g/dL fact',
  );
  _require(report.type == 'lab', 'report category lab');
  final event = report.eventDate;
  _require(
    event != null && event.year == 2026 && event.month == 3 && event.day == 14,
    'report clinical date 2026-03-14',
  );
  _require(
    report.summaryMarkdown?.isNotEmpty == true &&
        report.summaryMarkdown!.contains('11.2'),
    'Markdown summary carries fixture value',
  );
  return dim;
}

/// Calls the production native generator, recording structure/timing metadata
/// only. No output, prompt, transcript or medical data enters diagnostics.
class _DeviceIntelligence extends LocalIntelligence {
  @override
  Future<String> generate(String instruction, String input) async {
    final role = instruction.startsWith(organizerPrompt)
        ? 'organizer'
        : instruction.startsWith(extractorPrompt)
        ? 'extractor'
        : instruction.startsWith(summaryPrompt)
        ? 'summary'
        : 'assistant';
    final timer = Stopwatch()..start();
    try {
      final result = await super.generate(instruction, input);
      final raw = result.trim();
      final shape = raw.isEmpty
          ? 'empty'
          : raw.startsWith('```')
          ? 'fenced'
          : raw.startsWith('{')
          ? 'object'
          : 'text';
      debugPrint(
        'AYUMITRA_DEVICE GENERATE role=$role shape=$shape ms=${timer.elapsedMilliseconds}',
      );
      return result;
    } catch (error) {
      debugPrint(
        'AYUMITRA_DEVICE GENERATE_FAILED role=$role type=${error.runtimeType} backend=${activeBackend ?? 'none'}',
      );
      rethrow;
    }
  }
}

class _DeviceWebSearch extends WebSearch {
  int calls = 0;
  @override
  Future<List<WebSource>> search(String query) async {
    calls++;
    debugPrint('AYUMITRA_DEVICE WEB_CALL $calls');
    return super.search(query);
  }
}

class _DeviceController extends AppController {
  _DeviceController()
    : super(intelligence: _DeviceIntelligence(), webSearch: _DeviceWebSearch());
  @override
  bool get automaticModelsSupported => true;
}

Future<void> _installModels(AppController c) async {
  _require(
    c.intelligence.runtimeType == _DeviceIntelligence,
    'instrumented production native intelligence (no host bridge)',
  );
  _require(
    c.embeddings.runtimeType == LocalEmbeddings,
    'exact LocalEmbeddings core (no subclass)',
  );
  final timer = Stopwatch()..start();
  await c.ensureAutomaticModels();
  _require(
    c.modelSetupProgress?.state == 'ready',
    'automatic fixed model pair ready',
  );
  _require(
    c.intelligence.available && c.embeddings.available,
    'automatic native models configured',
  );
  final support = await getApplicationSupportDirectory();
  _require(
    c.data.modelType == 'gemma4' &&
        c.data.modelPath ==
            '${support.path}/ayumitra-models/${DefaultModel.assistant.filename}',
    'assistant verified private artifact selected',
  );
  _require(
    c.data.embeddingVersion == DefaultModel.embedding.sha256,
    'embedding artifact fingerprint verified',
  );
  debugPrint('AYUMITRA_DEVICE AUTOMATIC_SETUP_MS ${timer.elapsedMilliseconds}');
  // A real independent EG2 call separates embedding runtime from generation.
  final vector = await c.embeddings.embed('Synthetic local search fixture');
  _require(
    vector.isNotEmpty && vector.every((v) => v.isFinite),
    'independent native EG2 query finite',
  );
  debugPrint('AYUMITRA_DEVICE QUERY_VECTOR_DIM ${vector.length}');
}

Future<void> _setupTask(AppController c) async {
  _stage('profile');
  _require(c.profile?.history == _marker, 'DOB profile/background created');
  _require(
    c.activeSession?.turns.length == 1 &&
        c.data.memories.any((m) => m.profileId == c.activeProfileId),
    'background seeds session and memory',
  );
  final owner = c.profile!.id;

  _stage('import');
  await _importFixture(c);

  await _queryUpdateChecks(c, owner);

  _stage('isolation');
  await c.createProfile(
    'Synthetic Device Other Profile',
    DateTime(1990, 1, 1),
    '',
    false,
  );
  _require(
    c.reports.isEmpty && c.messages.isEmpty,
    'second profile isolates reports and memory',
  );
  await c.selectProfile(owner);
  _require(
    c.reports.any((r) => r.facts.any((f) => f.value == '11.2')),
    'owner reports intact after isolation check',
  );
}

/// Writes the synthetic TXT and imports it through the production path.
/// Timed as IMPORT_MS. Validates the imported report before returning it.
Future<void> _importFixture(AppController c) async {
  final scratch = Directory(
    '${(await getTemporaryDirectory()).path}/ayumitra-device-core',
  );
  await scratch.create(recursive: true);
  final picked = File('${scratch.path}/$_fileName');
  final bytes = utf8.encode(_text);
  await picked.writeAsBytes(bytes, flush: true);
  final importClock = Stopwatch()..start();
  try {
    await c.importFile(NativePickedFile(picked.path));
  } finally {
    if (await picked.exists()) await picked.delete();
  }
  importClock.stop();
  debugPrint('AYUMITRA_DEVICE IMPORT_MS ${importClock.elapsedMilliseconds}');
  final report = _reportByName(c);
  _require(report != null, 'synthetic report present by file name');
  _checkReportCore(report!);
  await _checkOriginal(c, report, bytes);
}

Report? _reportByName(AppController c) {
  for (final r in c.reports) {
    if (r.name == _fileName) return r;
  }
  return null;
}

/// Continues an interrupted run on the existing marked profile: imports the
/// fixture only when its report is missing, otherwise validates the exact
/// file name plus expected bytes and continues without deleting, rewriting,
/// or touching any other profile.
Future<void> _resumeTask(AppController c) async {
  _stage('resume');
  final owner = _ownedProfileId(c);
  _require(owner != null, 'own synthetic profile present for resume');
  await c.selectProfile(owner!);
  if (_reportByName(c) == null) {
    _stage('import');
    await _importFixture(c);
  } else {
    final report = _reportByName(c)!;
    final original = await c.vault.readOriginal(report, owner);
    _require(
      sha256.convert(original) == sha256.convert(utf8.encode(_text)),
      'resume report matches expected fixture bytes',
    );
    if (report.status == ReportStatus.needsReview ||
        report.summaryMarkdown?.isNotEmpty != true) {
      // Partial parse from an earlier run (e.g. before a bugfix): rerun the
      // existing public processing path, then revalidate the fresh copy.
      // Any other state is validated as-is; nothing is invented here.
      _stage('reprocess');
      await c.retry(report);
    } else {
      debugPrint('AYUMITRA_DEVICE REPROCESS skipped');
    }
    final current = _reportByName(c);
    _require(current != null, 'resumed report present by file name');
    _checkReportCore(current!);
    await _checkOriginal(c, current, utf8.encode(_text));
  }
  await _queryUpdateChecks(c, owner);
}

Future<void> _queryUpdateChecks(AppController c, String owner) async {
  _stage('query');
  final queryClock = Stopwatch()..start();
  await c.ask(_question);
  queryClock.stop();
  debugPrint('AYUMITRA_DEVICE QUERY_MS ${queryClock.elapsedMilliseconds}');
  _require(c.messages.isNotEmpty, 'answer message present');
  final answer = c.messages.last;
  _require(
    !answer.isUser &&
        answer.text.contains('11.2') &&
        answer.text.contains('g/dL'),
    'local answer gives fixture value and unit',
  );
  _require(
    answer.hits.isNotEmpty &&
        answer.hits.every(
          (h) =>
              h.report.profileId == owner &&
              answer.text.contains('[${h.citation}]'),
        ),
    'answer cites only owned files',
  );

  _stage('chat-update');
  final originals = c.reports.map((r) => r.digest).toList();
  await c.ask(_update);
  _require(c.messages.isNotEmpty, 'update acknowledgement present');
  final update = c.messages.last;
  _require(
    !update.isUser &&
        _hasReportedValue(update.text) &&
        update.text.contains('[conversation:${c.activeSessionId}]'),
    'local model acknowledges update with conversation provenance',
  );
  _require(
    update.text.toLowerCase().contains('report') && update.text.contains('?'),
    'uncorroborated update asks for a report',
  );
  _require(
    update.hits.every(
      (h) => !h.line.text.contains('11.2') || update.text.contains('11.2'),
    ),
    'old report cannot corroborate the new value silently',
  );
  _require(
    c.data.memories.any(
      (m) => m.profileId == owner && m.text.contains('13 g/dL'),
    ),
    'user observation saved in profile memory',
  );
  var reportedOn = '';
  for (final t in c.activeSession!.turns) {
    if (t.role == 'user' && t.text == _update) {
      reportedOn = t.createdAt.toIso8601String().split('T').first;
    }
  }
  _require(reportedOn.isNotEmpty, 'update turn carries provided date');
  await c.ask(_recall);
  _require(c.messages.isNotEmpty, 'recall answer present');
  final recalled = c.messages.last;
  _require(
    !recalled.isUser &&
        _hasReportedValue(recalled.text) &&
        recalled.text.contains('[conversation:${c.activeSessionId}]') &&
        recalled.text.contains(reportedOn),
    'local model recalls current value with provided date',
  );
  _require(
    c.reports.map((r) => r.digest).join() == originals.join() &&
        c.reports.every((r) => r.facts.any((f) => f.value == '11.2')),
    'chat update preserves original dated report values',
  );
  _stage('dated-history');
  await c.ask(_question);
  final historical = c.messages.last;
  _require(
    !historical.isUser &&
        historical.text.contains('11.2') &&
        historical.text.contains('g/dL') &&
        historical.hits.isNotEmpty &&
        historical.hits.every(
          (h) =>
              h.report.profileId == owner &&
              historical.text.contains('[${h.citation}]'),
        ),
    'dated report answer remains 11.2 after current user update',
  );
}

Future<void> _restoreTask(AppController c) async {
  _stage('restore');
  final owner = _ownedProfileId(c);
  _require(owner != null, 'own synthetic profile present after restart');
  await c.selectProfile(owner!);
  _require(c.reports.length == 1, 'own synthetic file present after restart');
  final report = c.reports.single;
  _checkReportCore(report);
  await _checkOriginal(c, report, utf8.encode(_text));
  _require(
    c.data.memories.any(
      (m) => m.profileId == owner && m.text.contains('13 g/dL'),
    ),
    'user observation restored from encrypted memory',
  );
  _require(
    c.data.memories.any((m) => m.profileId == owner),
    'session memory survives process restart',
  );
  _require(
    c.messages.any(
      (m) => !m.isUser && m.text.contains('11.2') && m.hits.isNotEmpty,
    ),
    'cited answer survives process restart',
  );
}

Future<void> _deletionTask(AppController c) async {
  _stage('deletion');
  final owner = _ownedProfileId(c);
  _require(owner != null, 'own synthetic profile present for deletion task');
  await c.selectProfile(owner!);
  _require(
    c.reports.any((r) => r.facts.any((f) => f.value == '11.2')),
    'own synthetic file present before deletion task',
  );
  final profilesBefore = c.data.profiles.length;
  final target = c.activeSessionId;
  _require(target != null, 'active conversation present for deletion task');
  await c.deleteConversation(target!);
  _require(
    c.data.memories.every((m) => m.sessionId != target || m.profileId != owner),
    'conversation delete clears its derived memory',
  );
  _require(
    c.reports.any((r) => r.facts.any((f) => f.value == '11.2')),
    'conversation delete preserves report files',
  );
  _require(
    c.data.profiles.length == profilesBefore,
    'deletion task removes no profile',
  );
}

Future<void> _exercise(AppController c) async {
  _require(c.loaded, 'Android encrypted vault opened');
  _require(c.intelligence.available, 'installed local Gemma 4 verified');
  _require(c.embeddings.available, 'installed local EmbeddingGemma 2 verified');
  if (_web) {
    _stage('web-search');
    _require(c.webSearch.available, 'Brave API key configured on device');
    await c.newConversation();
    await c.ask(
      "What is the name of Apple's folding iPhone? Check current public web sources and include a source reference. Do not rely on model memory.",
    );
    final answer = c.messages.last;
    _require(
      (c.webSearch as _DeviceWebSearch).calls > 0,
      'actual public search HTTP tool called',
    );
    _require(
      !answer.isUser && answer.web.isNotEmpty,
      'web sources retained with answer',
    );
    _require(
      answer.text.toLowerCase().contains('iphone duo'),
      'current folding phone name found',
    );
    _require(
      answer.web.any((s) => answer.text.contains('[${s.id}]')),
      'answer cites fetched web evidence',
    );
    _require(
      answer.web.every(
        (s) =>
            s.retrievedAt.difference(DateTime.now().toUtc()).abs() <
            const Duration(minutes: 5),
      ),
      'fresh source retrieval dates',
    );
    return;
  }
  // No public searches in the medical fixture check.
  c.webSearch.apiKey = null;
  if (_deletion) {
    await _deletionTask(c);
  } else if (_restoreOnly) {
    await _restoreTask(c);
  } else if (_resume) {
    await _resumeTask(c);
  } else {
    await _setupTask(c);
  }
  // Actual backend, read only after real inference ran. Setup/resume modes
  // ran generate; restore/deletion modes may legitimately report none-yet.
  final backend = c.intelligence.activeBackend;
  debugPrint('AYUMITRA_DEVICE BACKEND ${backend ?? 'none-yet'}');
  final index = await File('${c.vault.directory.path}/index.enc').readAsBytes();
  _require(
    !latin1.decode(index).contains(_marker) &&
        !latin1.decode(index).contains('11.2'),
    'health-bearing index stored as ciphertext',
  );
}

Future<void> main() async {
  _requireDeviceDebugBuild(kDebugMode);
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';
  await initializeDateFormatting('en_US');
  registerAyumitraNotices();
  FlutterError.onError = (d) =>
      debugPrint('AYUMITRA_DEVICE UI_ERROR ${d.exception.runtimeType}');
  final c = _DeviceController();
  runApp(AyumitraApp(controller: c));
  var stage = 'initialize';
  try {
    await pdfrxFlutterInitialize();
    await c.initialize();
    // Model installation reindexes the active profile. Select only our
    // synthetic owner before setup so unrelated profiles are never reindexed.
    final owner = _ownedProfileId(c);
    if (_restoreOnly || _resume || _deletion || _web) {
      _require(
        owner != null,
        'own synthetic profile present for selected mode',
      );
      await c.selectProfile(owner!);
    } else {
      _require(owner == null, 'no stale synthetic device profile (use resume)');
      await c.createProfile(
        'Synthetic Device Child',
        DateTime(2020, 1, 15),
        _marker,
        true,
      );
    }
    stage = 'models';
    _stage(stage);
    await _installModels(c);
    stage = 'exercise';
    await _exercise(c);
    debugPrint(
      'AYUMITRA_DEVICE ALL_PASS restore=$_restoreOnly resume=$_resume deletion=$_deletion',
    );
  } catch (error) {
    // Only these assertion messages are fixture metadata; never print model,
    // prompt, transcript, key, or vault bodies.
    debugPrint('AYUMITRA_DEVICE FAILED stage=$stage type=${error.runtimeType}');
    if (error is _DeviceCheckFailure) {
      debugPrint('AYUMITRA_DEVICE CHECK ${error.check}');
      debugPrint(
        'AYUMITRA_DEVICE LAST_STEP ${c.activity.isNotEmpty ? c.activity : c.stepLog.lastOrNull ?? 'none'}',
      );
    }
  }
}
