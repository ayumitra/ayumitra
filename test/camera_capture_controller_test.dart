import 'dart:convert';
import 'dart:io';

import 'package:ayumitra/app_controller.dart';
import 'package:ayumitra/domain/camera_pages.dart';
import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/services/camera_cache.dart';
import 'package:ayumitra/services/local_intelligence.dart';
import 'package:ayumitra/services/local_parser.dart';
import 'package:ayumitra/storage/encrypted_vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

class _StorageOnlyIntelligence extends LocalIntelligence {
  @override
  bool get available => false;
  @override
  Future<String> generate(String instruction, String input) async =>
      throw StateError('Storage-only fixture must never invoke a model.');
}

class _CameraPicker extends ImagePicker {
  final captures = <XFile?>[];
  LostDataResponse lost = LostDataResponse.empty();
  Future<void> Function(int)? beforeCapture;
  PlatformException? error;
  int calls = 0;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    expect(source, ImageSource.camera);
    expect(preferredCameraDevice, CameraDevice.rear);
    expect(requestFullMetadata, isFalse);
    final index = calls++;
    await beforeCapture?.call(index);
    if (error != null) throw error!;
    return index < captures.length ? captures[index] : null;
  }

  @override
  Future<LostDataResponse> retrieveLostData() async => lost;
}

class _CaptureVault extends EncryptedVault {
  _CaptureVault({
    required super.directory,
    required super.key,
    required this.secure,
  });
  final FlutterSecureStorage secure;
  bool failIndexSave = false;
  int originalChecks = 0;
  @override
  Future<void> saveOriginal(Report report, Uint8List bytes) async {
    final journal =
        jsonDecode((await secure.read(key: AppController.cameraPendingKey))!)
            as Map;
    expect(journal['profileId'], report.profileId);
    for (final path in (journal['paths'] as List).cast<String>()) {
      expect(await File(path).exists(), isTrue);
    }
    await super.saveOriginal(report, bytes);
    final encrypted = await File(
      '${directory.path}/originals/${report.profileId}/${report.id}.enc',
    ).readAsBytes();
    expect(encrypted, isNot(equals(bytes)));
    expect(await super.readOriginal(report, report.profileId), bytes);
    originalChecks++;
  }

  @override
  Future<void> save(VaultData data) async {
    if (failIndexSave) {
      throw const FileSystemException('Synthetic index save failure');
    }
    await super.save(data);
  }
}

Profile _owner(String id) => Profile(
  id: id,
  name: 'Synthetic $id',
  history: '',
  dateOfBirth: DateTime(2000),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, cache;
  late _CameraPicker picker;
  late _CaptureVault vault;
  late AppController c;
  const secure = FlutterSecureStorage();
  final images = <Uint8List>[];
  final photos = <File>[];
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp(
      'ayumitra-camera-capture-test-',
    );
    cache = Directory('${root.path}/camera')..createSync();
    picker = _CameraPicker();
    vault = _CaptureVault(
      directory: Directory('${root.path}/vault'),
      key: await AesGcm.with256bits().newSecretKey(),
      secure: secure,
    );
    images.clear();
    photos.clear();
    for (var i = 0; i < 6; i++) {
      final image = img.Image(width: 8, height: 8)
        ..clear(img.ColorRgb8(30 + i * 25, 80, 120));
      final bytes = Uint8List.fromList(img.encodeJpg(image));
      final file = File(
        '${cache.path}/11111111-1111-1111-1111-111111111111${i + 1}.jpg',
      );
      await file.writeAsBytes(bytes);
      images.add(bytes);
      photos.add(file);
    }
    c =
        AppController(
            intelligence: _StorageOnlyIntelligence(),
            imagePicker: picker,
            secureStorage: secure,
          )
          ..loaded = true
          ..activeProfileId = 'alice'
          ..data = VaultData(
            profiles: [_owner('alice'), _owner('bob')],
            activeProfileId: 'alice',
          )
          ..vault = vault
          ..cameraCache = CameraCache(cache, ios: false)
          ..parser = LocalParser(
            Directory('${root.path}/scratch'),
            transcribe: (_) async => [],
          );
    await vault.save(c.data);
  });
  tearDown(() async {
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<void> journalFor(String owner, List<File> files) => secure.write(
    key: AppController.cameraPendingKey,
    value: jsonEncode({
      'profileId': owner,
      'paths': files.map((file) => file.path).toList(),
    }),
  );

  test(
    'one photograph preserves exact JPEG and erases plaintext only after encrypted saving',
    () async {
      picker.captures.add(XFile(photos.first.path));
      picker.beforeCapture = (_) async {
        final journal =
            jsonDecode(
                  (await secure.read(key: AppController.cameraPendingKey))!,
                )
                as Map;
        expect(journal, {'profileId': 'alice', 'paths': []});
      };
      await c.captureReportPages();
      expect(c.data.reports.length, 1);
      final report = c.data.reports.single;
      expect(report.profileId, 'alice');
      expect(report.extension, 'jpg');
      expect(await vault.readOriginal(report, 'alice'), images.first);
      expect(vault.originalChecks, 1);
      expect(await photos.first.exists(), isFalse);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
      expect(c.data.processingJobs.single.profileId, 'alice');
      expect(report.status, ReportStatus.needsReview);
    },
  );
  test(
    'multiple photographs group ordered original pages and journal survives before each picker call',
    () async {
      picker.captures.addAll([XFile(photos[0].path), XFile(photos[1].path)]);
      picker.beforeCapture = (index) async {
        final journal =
            jsonDecode(
                  (await secure.read(key: AppController.cameraPendingKey))!,
                )
                as Map;
        expect(journal['profileId'], 'alice');
        expect(journal['paths'], index == 0 ? [] : [photos[0].path]);
      };
      await c.captureReportPages(onAnotherPage: (count) async => count < 2);
      expect(picker.calls, 2);
      final report = c.data.reports.single;
      expect(report.extension, 'images');
      final pages = CameraPages.decode(
        await vault.readOriginal(report, 'alice'),
      );
      expect(pages, [images[0], images[1]]);
      expect(await photos[0].exists(), isFalse);
      expect(await photos[1].exists(), isFalse);
      expect(await photos[2].exists(), isTrue);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
    },
  );
  test(
    'capture limits to five pages even when another-page callback always requests more',
    () async {
      picker.captures.addAll(photos.map((file) => XFile(file.path)));
      var questions = 0;
      await c.captureReportPages(
        onAnotherPage: (_) async {
          questions++;
          return true;
        },
      );
      expect(picker.calls, CameraPages.maxPages);
      expect(questions, CameraPages.maxPages - 1);
      final pages = CameraPages.decode(
        await vault.readOriginal(c.data.reports.single, 'alice'),
      );
      expect(pages, images.take(CameraPages.maxPages).toList());
      expect(await photos.last.exists(), isTrue);
    },
  );
  test(
    'first-page cancellation produces no report and clears recovery journal',
    () async {
      picker.captures.add(null);
      await c.captureReportPages();
      expect(c.data.reports, isEmpty);
      expect(c.data.processingJobs, isEmpty);
      expect(vault.originalChecks, 0);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
    },
  );
  test('cancelling a later capture still saves prior original page', () async {
    picker.captures.addAll([XFile(photos[0].path), null]);
    await c.captureReportPages(onAnotherPage: (_) async => true);
    expect(picker.calls, 2);
    final report = c.data.reports.single;
    expect(report.extension, 'jpg');
    expect(await vault.readOriginal(report, 'alice'), images[0]);
    expect(await photos[0].exists(), isFalse);
    expect(await secure.read(key: AppController.cameraPendingKey), isNull);
  });
  test(
    'recovered pages belong to journal owner despite a different active profile',
    () async {
      c.activeProfileId = 'bob';
      c.data = c.data.copy(activeProfileId: 'bob');
      await journalFor('alice', [photos[0]]);
      picker.lost = LostDataResponse(files: [XFile(photos[1].path)]);
      await c.recoverCameraCapture();
      expect(c.activeProfileId, 'bob');
      expect(c.data.activeProfileId, 'bob');
      expect(c.messages, isEmpty);
      expect(c.data.sessions, isEmpty);
      expect(c.data.memories, isEmpty);
      final report = c.data.reports.single;
      expect(report.profileId, 'alice');
      expect(CameraPages.decode(await vault.readOriginal(report, 'alice')), [
        images[0],
        images[1],
      ]);
      expect(report.lines, isEmpty);
      expect(c.data.processingJobs.single.profileId, 'alice');
      expect(c.data.processingJobs.single.attempts, 0);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
    },
  );
  test(
    'pending empty-path journal captures Android lost-data response with original owner',
    () async {
      await journalFor('alice', []);
      picker.lost = LostDataResponse(files: [XFile(photos[0].path)]);
      await c.recoverCameraCapture();
      expect(c.data.reports.single.profileId, 'alice');
      expect(
        await vault.readOriginal(c.data.reports.single, 'alice'),
        images[0],
      );
      expect(await photos[0].exists(), isFalse);
    },
  );
  test(
    'failed index save retains capture and recovery journal until durable recovery succeeds',
    () async {
      picker.captures.add(XFile(photos[0].path));
      vault.failIndexSave = true;
      await c.captureReportPages();
      expect(c.data.reports, isEmpty);
      expect(await photos[0].exists(), isTrue);
      final pending =
          jsonDecode((await secure.read(key: AppController.cameraPendingKey))!)
              as Map;
      expect(pending['profileId'], 'alice');
      expect(pending['paths'], [photos[0].path]);
      vault.failIndexSave = false;
      await c.recoverCameraCapture();
      expect(c.data.reports.length, 1);
      expect(
        await vault.readOriginal(c.data.reports.single, 'alice'),
        images[0],
      );
      expect(await photos[0].exists(), isFalse);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
      expect((await vault.read()).reports.length, 1);
    },
  );
  test(
    'camera permission denial provides recovery guidance without a report',
    () async {
      picker.error = PlatformException(code: 'camera_access_denied');
      await c.captureReportPages();
      expect(c.failure, contains('Camera permission'));
      expect(c.data.reports, isEmpty);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
    },
  );
  test(
    'lost captures with no journal or missing owner never attach to active profile',
    () async {
      picker.lost = LostDataResponse(files: [XFile(photos[0].path)]);
      await c.recoverCameraCapture();
      expect(c.data.reports, isEmpty);
      expect(await photos[0].exists(), isFalse);
      await journalFor('removed-owner', [photos[1]]);
      picker.lost = LostDataResponse.empty();
      await c.recoverCameraCapture();
      expect(c.data.reports, isEmpty);
      expect(c.data.processingJobs, isEmpty);
      expect(await photos[1].exists(), isFalse);
      expect(await secure.read(key: AppController.cameraPendingKey), isNull);
    },
  );
  test('an unowned external image is never imported or deleted', () async {
    final external = File('${root.path}/external.jpg')
      ..writeAsBytesSync(images[0]);
    picker.captures.add(XFile(external.path));
    await c.captureReportPages();
    expect(c.data.reports, isEmpty);
    expect(await external.exists(), isTrue);
    expect(c.failure, isNotNull);
  });
}
