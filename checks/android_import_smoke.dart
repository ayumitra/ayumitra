// Synthetic-only Android import checks. Never use this in release.
// Default: production on-device Gemma 4 and EmbeddingGemma 2. Opt-in HOST mode
// uses only verified models on the developer's computer through adb reverse;
// it tests Android's encrypted vault but does not certify on-device inference.
// Public search and cloud inference are forbidden in both modes.
//
// Stage the exact public repository fixtures with SDK tools, under the app's
// private files/ayumitra-import-fixtures directory, preserving their names:
//   F01_cbc_digital.pdf (default), F02_prescription_scan.png (SCAN), or
//   F03_prescription_camera.png (CAMERA).
// The manifest SHA-256 is checked before creating or selecting a test profile.
// Build checks/android_import_smoke.dart as a debug APK, install with adb -r
// (abort on failure; never uninstall), then launch our own MainActivity.
//
// Select exactly one lane with --dart-define=AYUMITRA_IMPORT_SCAN=true or
// --dart-define=AYUMITRA_IMPORT_CAMERA=true. With neither, test digital PDF.
// --dart-define=AYUMITRA_IMPORT_HOST=true uses the verified loopback bridge;
// run adb reverse tcp:11434 tcp:11434 first. Model tags match main_emulator.
// --dart-define=AYUMITRA_IMPORT_CAMERA_PAGES=2 exercises grouped camera capture
// with 1–5 synthetic page results. Page count is meaningful only in CAMERA mode.
// --dart-define=AYUMITRA_IMPORT_RESUME=true reuses only this lane's own profile.
// --dart-define=AYUMITRA_IMPORT_RESTORE=true verifies persisted data only; it
// never installs models, imports, retries, edits or deletes any saved report.
// Each lane owns a separate marker/profile; unrelated profiles/keys are kept.
//
// CAMERA substitutes only the picker result with a synthetic JPEG. It invokes
// production captureReportPages(), including encrypted saving and CameraCache
// cleanup, and real local vision inference. It DOES NOT test a physical shutter,
// Android camera permission, the native camera intent, or camera hardware.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/camera_pages.dart';
import 'package:ayumitra/domain/extraction.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/emulator/emulator_controller.dart';
import 'package:ayumitra/services/automatic_models.dart';
import 'package:ayumitra/services/local_embeddings.dart';
import 'package:ayumitra/services/local_file_picker.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/notice_registry.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/services/web_search.dart';
import 'package:ayumitra/ui/app.dart';

const _scan = bool.fromEnvironment('AYUMITRA_IMPORT_SCAN');
const _camera = bool.fromEnvironment('AYUMITRA_IMPORT_CAMERA');
const _resume = bool.fromEnvironment('AYUMITRA_IMPORT_RESUME');
const _restore = bool.fromEnvironment('AYUMITRA_IMPORT_RESTORE');
const _host = bool.fromEnvironment('AYUMITRA_IMPORT_HOST');
const _cameraPageCount = int.fromEnvironment(
  'AYUMITRA_IMPORT_CAMERA_PAGES',
  defaultValue: 1,
);
const _lane = _camera ? 'camera' : (_scan ? 'scan' : 'pdf');
const _marker =
    'AYUMITRA_SYNTHETIC_IMPORT_V1_$_lane'
    '${_host ? '_host' : ''}'
    '${_camera && _cameraPageCount > 1 ? '_pages$_cameraPageCount' : ''}';
const _fileName = _camera
    ? 'F03_prescription_camera.png'
    : (_scan ? 'F02_prescription_scan.png' : 'F01_cbc_digital.pdf');
const _fixtureSha = _camera
    ? '54825bc993a90d7a852d28614a48083d7070893c00506beaafbba8134e2697cf'
    : (_scan
          ? '92be5df2769bfcb21dcf553c15131451b1a2da2e9404f8647893373b9db61166'
          : '7b3a299acd6965ff2846aa9a786458c72c53b84479146dff16bd6675889af479');
// An Android image_picker-owned direct cache child. No arbitrary cache path is
// deleted. Initializing the controller sweeps stale plugin caches BEFORE this
// harness writes its fixture here.
String _cameraCacheName(int page) =>
    'a97f5f32-c7b5-4191-bf11-92e812033ba7${1000 + page}.jpg';

class _ImportFailure implements Exception {
  const _ImportFailure(this.check);
  final String check;
}

void _require(bool condition, String check) {
  if (!condition) throw _ImportFailure(check);
  debugPrint('AYUMITRA_IMPORT PASS $check');
}

void _stage(String stage) => debugPrint('AYUMITRA_IMPORT STAGE $stage');

class _NoPublicSearch extends WebSearch {
  @override
  Future<List<WebSource>> search(String query) async {
    throw const _ImportFailure('public search forbidden in synthetic import');
  }
}

/// Only structure/timing/error-type metadata is logged, never model text,
/// prompts, transcript lines, private filenames, credentials or patient data.
class _ImportIntelligence extends LocalIntelligence {
  @override
  Future<String> generate(String instruction, String input) async {
    final role = instruction.startsWith(summaryPrompt)
        ? 'markdown'
        : 'assistant';
    final timer = Stopwatch()..start();
    try {
      final output = await super.generate(instruction, input);
      final raw = output.trim();
      final shape = raw.isEmpty
          ? 'empty'
          : raw.startsWith('```')
          ? 'fenced'
          : raw.startsWith('{')
          ? 'object'
          : 'text';
      debugPrint(
        'AYUMITRA_IMPORT GENERATE role=$role shape=$shape ms=${timer.elapsedMilliseconds}',
      );
      return output;
    } catch (error) {
      debugPrint(
        'AYUMITRA_IMPORT GENERATE_FAILED role=$role type=${error.runtimeType}',
      );
      rethrow;
    }
  }

  @override
  Future<List<String>> transcribeImage(Uint8List bytes) async {
    final timer = Stopwatch()..start();
    try {
      final lines = await super.transcribeImage(bytes);
      debugPrint(
        'AYUMITRA_IMPORT VISION rows=${lines.length} ms=${timer.elapsedMilliseconds}',
      );
      return lines;
    } catch (error) {
      debugPrint('AYUMITRA_IMPORT VISION_FAILED type=${error.runtimeType}');
      rethrow;
    }
  }
}

class _ImportHostIntelligence extends WebIntelligence {
  @override
  Future<String> generate(String instruction, String input) async {
    final role = instruction.startsWith(summaryPrompt)
        ? 'markdown'
        : 'assistant';
    final timer = Stopwatch()..start();
    try {
      final output = await super.generate(instruction, input);
      final raw = output.trim();
      final shape = raw.isEmpty
          ? 'empty'
          : raw.startsWith('```')
          ? 'fenced'
          : raw.startsWith('{')
          ? 'object'
          : 'text';
      debugPrint(
        'AYUMITRA_IMPORT GENERATE role=$role shape=$shape ms=${timer.elapsedMilliseconds} mode=host-local',
      );
      return output;
    } catch (error) {
      debugPrint(
        'AYUMITRA_IMPORT GENERATE_FAILED role=$role type=${error.runtimeType} mode=host-local',
      );
      rethrow;
    }
  }

  @override
  Future<List<String>> transcribeImage(Uint8List bytes) async {
    final timer = Stopwatch()..start();
    try {
      final lines = await super.transcribeImage(bytes);
      debugPrint(
        'AYUMITRA_IMPORT VISION rows=${lines.length} ms=${timer.elapsedMilliseconds} mode=host-local',
      );
      return lines;
    } catch (error) {
      debugPrint(
        'AYUMITRA_IMPORT VISION_FAILED type=${error.runtimeType} mode=host-local',
      );
      rethrow;
    }
  }
}

class _SyntheticCameraPicker extends ImagePicker {
  final stagedPaths = <String>[];
  int calls = 0;
  bool get called => calls > 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    _require(source == ImageSource.camera, 'production requests camera source');
    _require(
      preferredCameraDevice == CameraDevice.rear && !requestFullMetadata,
      'production requests rear camera without full metadata',
    );
    _require(calls < stagedPaths.length, 'synthetic camera result staged');
    return XFile(stagedPaths[calls++]);
  }
}

class _ImportController extends AppController {
  _ImportController(_SyntheticCameraPicker picker)
    : super(
        intelligence: _host
            ? (_ImportHostIntelligence()
                ..endpoint = emulatorLocalEndpoint
                ..chatModel = emulatorChatModel
                ..visionModel = emulatorVisionModel)
            : _ImportIntelligence(),
        embeddings: _host
            ? (WebEmbeddings()
                ..endpoint = emulatorLocalEndpoint
                ..embeddingModel = emulatorEmbeddingModel)
            : LocalEmbeddings(),
        webSearch: _NoPublicSearch(),
        imagePicker: picker,
      );

  @override
  bool get automaticModelsSupported => !_host;
  @override
  bool get automaticProcessingChecksEnabled => false;

  bool skippedCameraRecovery = false;

  @override
  Future<void> recoverCameraCapture() async {
    // Never recover or process a user's unfinished camera capture inside a
    // synthetic harness. Abort after initialization, keeping its journal/files.
    skippedCameraRecovery = true;
  }

  @override
  Future<void> initialize() async {
    await super.initialize();
    if (!loaded || !_host || skippedCameraRecovery) return;
    await (intelligence as _ImportHostIntelligence).connect();
    await (embeddings as WebEmbeddings).connect();
    failure = null;
    refreshViews();
  }
}

Future<(File, Uint8List)> _fixture() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/ayumitra-import-fixtures');
  _require(await directory.exists(), 'private synthetic fixtures staged');
  final file = File('${directory.path}/$_fileName');
  _require(
    await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file,
    'synthetic fixture is regular file',
  );
  _require(
    File(await file.resolveSymbolicLinks()).parent.path ==
        await directory.resolveSymbolicLinks(),
    'synthetic fixture scoped to private fixture directory',
  );
  _require(
    await file.length() < 30 * 1024 * 1024,
    'fixture within import limit',
  );
  final original = await file.readAsBytes();
  _require(
    sha256.convert(original).toString() == _fixtureSha,
    'exact public synthetic fixture fingerprint',
  );
  if (!_camera) return (file, original);
  final decoded = img.decodePng(original);
  _require(decoded != null, 'synthetic camera fixture decodes');
  // Native Android camera results are JPEG. This deterministic conversion is
  // synthetic-only; preservation checks compare against these exact JPEG bytes.
  return (file, Uint8List.fromList(img.encodeJpg(decoded!, quality: 95)));
}

Report? _report(AppController c, String digest) => c.reports
    .where((r) => r.profileId == c.activeProfileId && r.digest == digest)
    .firstOrNull;

Future<void> _originalChecks(
  AppController c,
  Report report,
  Uint8List expected,
) async {
  final original = await c.vault.readOriginal(report, report.profileId);
  _require(
    sha256.convert(original) == sha256.convert(expected),
    'encrypted original restored byte for byte',
  );
  final encrypted = await File(
    '${c.vault.directory.path}/originals/${report.profileId}/${report.id}.enc',
  ).readAsBytes();
  _require(
    encrypted.length > expected.length &&
        sha256.convert(encrypted) != sha256.convert(expected),
    'original stored as ciphertext',
  );
  var denied = false;
  try {
    await c.vault.readOriginal(report, 'different-profile');
  } on StateError {
    denied = true;
  }
  _require(denied, 'original access denied across profile');
}

void _processedChecks(Report report) {
  _require(report.lines.isNotEmpty, 'native report has source rows');
  final expectedPages = _camera ? _cameraPageCount : 1;
  _require(
    report.lines.every(
          (line) =>
              line.page >= 1 &&
              line.page <= expectedPages &&
              RegExp('^p${line.page}-l[1-9][0-9]*\$').hasMatch(line.id) &&
              line.text.trim().isNotEmpty,
        ) &&
        report.lines.map((l) => l.id).toSet().length == report.lines.length,
    'nonempty unique source rows retain page identifiers',
  );
  _require(
    List.generate(
      expectedPages,
      (i) => i + 1,
    ).every((page) => report.lines.any((line) => line.page == page)),
    'every original page has source rows',
  );
  _require(
    report.extension ==
        (_camera && _cameraPageCount > 1
            ? 'images'
            : (_camera ? 'jpg' : (_scan ? 'png' : 'pdf'))),
    'single image or grouped report format retained',
  );
  if (_camera || _scan) {
    _require(
      report.lines.every((l) => l.method == 'vision' && l.bounds == null),
      'vision transcript is labeled and has no invented coordinates',
    );
    _require(
      report.status == ReportStatus.needsReview && report.notice != null,
      'vision transcript remains needs review',
    );
    _require(
      report.lines.any(
        (line) =>
            line.text.toLowerCase().contains('amoxicillin') &&
            RegExp(r'(?<![\d.])250(?:\.0+)?\b').hasMatch(line.text) &&
            line.text.contains('mg'),
      ),
      'source rows retain synthetic medicine name dose and unit',
    );
    _require(report.type == 'prescription', 'prescription category retained');
  } else {
    _require(
      report.lines.every(
        (l) =>
            l.method == 'text' &&
            l.bounds?.length == 4 &&
            l.bounds!.every((v) => v.isFinite) &&
            l.pageWidth != null &&
            l.pageHeight != null,
      ),
      'digital PDF retains native text and page coordinates',
    );
    _require(report.status == ReportStatus.ready, 'digital PDF ready');
    _require(
      report.lines.any(
        (line) => line.text.contains('11.2') && line.text.contains('g/dL'),
      ),
      'source rows retain synthetic hemoglobin value and unit',
    );
    _require(report.type == 'lab', 'lab category retained');
  }
  final expectedDay = (_camera || _scan) ? 15 : 14;
  _require(
    report.eventDate?.year == 2026 &&
        report.eventDate?.month == 3 &&
        report.eventDate?.day == expectedDay &&
        !report.dateIsFallback,
    'source clinical date retained without current-date fallback',
  );
  _require(
    report.vectors.length == report.lines.length &&
        report.lines.every((l) => report.vectors.containsKey(l.id)),
    'EmbeddingGemma 2 indexes every source row',
  );
  final dimension = report.vectors.values.first.length;
  _require(
    dimension > 0 &&
        report.vectors.values.every(
          (v) => v.length == dimension && v.every((x) => x.isFinite),
        ),
    'search vectors finite and dimension consistent',
  );
  debugPrint('AYUMITRA_IMPORT VECTOR_DIM $dimension');
  final summary = report.summaryMarkdown;
  final allowed = report.lines.map((l) => '${report.id}/${l.id}').toSet();
  _require(
    summary != null &&
        summary.trim().isNotEmpty &&
        validCitations(summary, allowed),
    'saved Markdown summary cites only owned report source rows',
  );
  _require(
    summary!.contains((_scan || _camera) ? '250' : '11.2') &&
        summary.contains((_scan || _camera) ? 'mg' : 'g/dL') &&
        (!(_scan || _camera) || summary.toLowerCase().contains('amoxicillin')),
    'saved Markdown notes retain exact fixture finding and unit',
  );
}

Future<void> _answerChecks(AppController c, Report report) async {
  await c.ask(
    (_scan || _camera)
        ? 'What Amoxicillin dose appears on the March 15, 2026 prescription? Give its unit and cite the report. Note that image text is unverified.'
        : 'What hemoglobin value appears on the March 14, 2026 report? Give its unit and cite the report.',
  );
  final answer = c.messages.lastOrNull;
  _require(
    answer != null && !answer.isUser,
    'report question answered locally',
  );
  final expected = (_scan || _camera)
      ? RegExp(r'(?<![\d.])250\s*mg\b', caseSensitive: false)
      : RegExp(r'(?<![\d.])11\.2\s*g/dL\b', caseSensitive: false);
  _require(
    expected.hasMatch(answer!.text.replaceAll(RegExp(r'[*_`]'), '')),
    'local answer preserves exact value and unit',
  );
  _require(
    answer.hits.any(
          (h) =>
              h.report.id == report.id &&
              answer.text.contains('[${h.citation}]'),
        ) &&
        answer.hits.every((h) => h.report.profileId == report.profileId),
    'answer references current profile original source',
  );
  _require(answer.web.isEmpty, 'no public web sources used for fixture');
}

Future<void> main() async {
  if (!kDebugMode || !Platform.isAndroid) {
    throw UnsupportedError('Import smoke checks require debug Android.');
  }
  _require(!(_scan && _camera), 'one import lane selected');
  _require(!(_restore && _resume), 'one persistence mode selected');
  _require(
    _cameraPageCount >= 1 &&
        _cameraPageCount <= CameraPages.maxPages &&
        (_camera || _cameraPageCount == 1),
    'camera count within one to five and camera lane only',
  );
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'en_US';
  await initializeDateFormatting('en_US');
  registerAyumitraNotices();
  FlutterError.onError = (d) =>
      debugPrint('AYUMITRA_IMPORT UI_ERROR ${d.exception.runtimeType}');
  final picker = _SyntheticCameraPicker();
  final c = _ImportController(picker);
  runApp(AyumitraApp(controller: c));
  var stage = 'fixture';
  final cameraCopies = <File>[];
  try {
    await pdfrxFlutterInitialize();
    final (fixture, imageBytes) = await _fixture();
    final bytes = _camera && _cameraPageCount > 1
        ? CameraPages.encode(List.generate(_cameraPageCount, (_) => imageBytes))
        : imageBytes;
    final digest = sha256.convert(bytes).toString();
    stage = 'initialize';
    _stage(stage);
    await c.initialize();
    _require(c.loaded, 'encrypted vault initialized');
    _require(
      !c.skippedCameraRecovery,
      'no unfinished user camera capture; journal preserved otherwise',
    );
    final matches = c.data.profiles.where((p) => p.history == _marker).toList();
    _require(matches.length <= 1, 'synthetic marker uniquely identifies owner');
    if (_resume || _restore) {
      _require(matches.length == 1, 'owned synthetic profile exists');
      await c.selectProfile(matches.single.id);
    } else {
      _require(matches.isEmpty, 'no stale lane profile; use resume');
      await c.createProfile(
        'Synthetic import $_lane test',
        DateTime(2020, 1, 15),
        _marker,
        true,
      );
    }
    _require(c.profile?.history == _marker, 'only owned profile selected');
    if (!_restore) {
      stage = 'models';
      _stage(stage);
      if (_host) {
        _require(
          c.intelligence.runtimeType == _ImportHostIntelligence &&
              c.embeddings.runtimeType == WebEmbeddings &&
              !c.automaticModelsSupported,
          'explicit verified host bridge; no native automatic setup',
        );
        final assistant = c.intelligence as _ImportHostIntelligence;
        final search = c.embeddings as WebEmbeddings;
        _require(
          assistant.available &&
              assistant.visionAvailable &&
              search.available &&
              assistant.endpoint == emulatorLocalEndpoint &&
              search.endpoint == emulatorLocalEndpoint &&
              assistant.chatModel == emulatorChatModel &&
              assistant.visionModel == emulatorVisionModel &&
              search.embeddingModel == emulatorEmbeddingModel,
          'fixed loopback host roles verified with vision',
        );
        _require(
          assistant.chatInfo?.digest.isNotEmpty == true &&
              assistant.chatInfo!.capabilities.contains('completion') &&
              assistant.visionInfo?.digest.isNotEmpty == true &&
              assistant.visionInfo!.capabilities.contains('vision') &&
              search.modelInfo?.digest.isNotEmpty == true &&
              search.modelInfo!.capabilities.contains('embedding'),
          'installed local digests and role capabilities verified',
        );
      } else {
        _require(
          c.intelligence.runtimeType == _ImportIntelligence &&
              c.embeddings.runtimeType == LocalEmbeddings,
          'production native generation and embedding runtimes',
        );
        await c.ensureAutomaticModels();
        _require(
          c.modelSetupProgress?.state == 'ready' &&
              c.intelligence.available &&
              c.embeddings.available &&
              c.data.modelType == 'gemma4' &&
              c.data.embeddingVersion == DefaultModel.embedding.sha256,
          'fixed verified local model pair configured automatically',
        );
      }
      stage = 'import';
      _stage(stage);
      final clock = Stopwatch()..start();
      final existing = _report(c, digest);
      if (existing == null) {
        if (_camera) {
          _stage('camera-simulated-picker-no-physical-shutter');
          final root = await getTemporaryDirectory();
          for (var page = 1; page <= _cameraPageCount; page++) {
            final copy = File('${root.path}/${_cameraCacheName(page)}');
            _require(
              await FileSystemEntity.type(copy.path, followLinks: false) ==
                  FileSystemEntityType.notFound,
              'distinct owned synthetic camera cache path unused',
            );
            // Track only our own copies for scoped finally cleanup, including
            // a partial file if writing is interrupted.
            cameraCopies.add(copy);
            await copy.writeAsBytes(imageBytes, flush: true);
            picker.stagedPaths.add(copy.path);
          }
          final capturePrompts = <int>[];
          await c.captureReportPages(
            onAnotherPage: (count) async {
              capturePrompts.add(count);
              return count < _cameraPageCount;
            },
          );
          _require(picker.called, 'production capture path invoked');
          _require(
            picker.calls == _cameraPageCount &&
                capturePrompts.length ==
                    (_cameraPageCount == CameraPages.maxPages
                        ? _cameraPageCount - 1
                        : _cameraPageCount) &&
                capturePrompts.indexed.every((p) => p.$2 == p.$1 + 1),
            'production captures every requested page in order',
          );
          for (final copy in cameraCopies) {
            _require(
              !await copy.exists(),
              'production camera path removes every temporary plaintext page',
            );
          }
        } else {
          await c.importFile(NativePickedFile(fixture.path));
          _require(await fixture.exists(), 'external fixture source preserved');
        }
      } else if (existing.lines.isEmpty ||
          existing.vectors.isEmpty ||
          existing.summaryMarkdown == null) {
        await c.retry(existing);
      }
      debugPrint('AYUMITRA_IMPORT IMPORT_MS ${clock.elapsedMilliseconds}');
    }
    stage = 'report';
    _stage(stage);
    final report = _report(c, digest);
    _require(report != null, 'exact original exists in owned profile');
    _processedChecks(report!);
    await _originalChecks(c, report, bytes);
    if (_camera && _cameraPageCount > 1) {
      final saved = CameraPages.decode(
        await c.vault.readOriginal(report, report.profileId),
      );
      _require(
        saved.length == _cameraPageCount &&
            saved.every(
              (page) => sha256.convert(page) == sha256.convert(imageBytes),
            ),
        'grouped original restores every exact image in capture order',
      );
    }
    if (!_restore) {
      stage = 'answer';
      _stage(stage);
      await _answerChecks(c, report);
    }
    final index = await File(
      '${c.vault.directory.path}/index.enc',
    ).readAsBytes();
    _require(
      !latin1.decode(index).contains(_marker),
      'profile and report index stored as ciphertext',
    );
    debugPrint(
      'AYUMITRA_IMPORT ALL_PASS lane=$_lane pages=${_camera ? _cameraPageCount : 1} host=$_host restore=$_restore resume=$_resume backend=${_host ? 'developer-local-server' : c.intelligence.activeBackend ?? 'none-yet'}',
    );
    if (_camera) {
      debugPrint('AYUMITRA_IMPORT CAMERA_SCOPE simulated-picker-only');
    }
  } catch (error) {
    debugPrint('AYUMITRA_IMPORT FAILED stage=$stage type=${error.runtimeType}');
    if (error is _ImportFailure) {
      debugPrint('AYUMITRA_IMPORT CHECK ${error.check}');
    }
  } finally {
    // Scoped production cleanup; no arbitrary file deletion, vault clearing,
    // profile removal, credential modification, or whole-directory sweep.
    for (final copy in cameraCopies) {
      await c.cameraCache.remove(copy.path);
    }
  }
}
