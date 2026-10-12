// Sub-owned tests for the camera-cache privacy helper (MSG-033).
// Written by Sub; executed by Main (no concurrent Flutter runs).
// Uses real temp directories and synthetic files only.
// forDevice() is intentionally NOT covered here: it needs plugin platform
// channels (path_provider / privacy channel); Main integration-tests it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ayumitra/services/camera_cache.dart';

const _uuid = '123e4567-e89b-12d3-a456-426614174000';
String _androidOwned(String suffix) => '$_uuid$suffix.jpg';

Directory _temp(String prefix) =>
    Directory.systemTemp.createTempSync('ayumitra_camtest_$prefix');

void _touch(Directory dir, String name, [List<int> bytes = const [1, 2, 3]]) {
  File(
    '${dir.path}${Platform.pathSeparator}$name',
  ).writeAsBytesSync(bytes, flush: true);
}

bool _exists(Directory dir, String name) =>
    File('${dir.path}${Platform.pathSeparator}$name').existsSync();

void main() {
  late Directory dir;
  late Directory outside;
  setUp(() {
    dir = _temp('root');
    outside = _temp('outside');
  });
  tearDown(() {
    for (final d in [dir, outside]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  group('owned deletion (Android plugin pattern)', () {
    test('clean removes UUID+numeric .jpg files directly under root', () async {
      _touch(dir, _androidOwned('0'));
      _touch(dir, _androidOwned('987654321'));
      await CameraCache(dir, ios: false).clean();
      expect(_exists(dir, _androidOwned('0')), isFalse);
      expect(_exists(dir, _androidOwned('987654321')), isFalse);
    });

    test(
      'clean keeps lookalikes: bare UUID, other extensions, prefixes',
      () async {
        _touch(dir, '$_uuid.jpg'); // no Java numeric suffix: not owned
        _touch(dir, '${_uuid}7.png'); // Android owned is .jpg only
        _touch(dir, 'my_${_uuid}9.jpg'); // owned pattern must start at UUID
        _touch(dir, 'photo.jpg');
        await CameraCache(dir, ios: false).clean();
        expect(_exists(dir, '$_uuid.jpg'), isTrue);
        expect(_exists(dir, '${_uuid}7.png'), isTrue);
        expect(_exists(dir, 'my_${_uuid}9.jpg'), isTrue);
        expect(_exists(dir, 'photo.jpg'), isTrue);
      },
    );

    test('clean never recurses into subdirectories', () async {
      final sub = Directory('${dir.path}${Platform.pathSeparator}sub')
        ..createSync();
      _touch(sub, _androidOwned('1'));
      await CameraCache(dir, ios: false).clean();
      expect(_exists(sub, _androidOwned('1')), isTrue);
    });

    test('iOS helper ignores Android-pattern files and vice versa', () async {
      _touch(dir, _androidOwned('3'));
      _touch(dir, 'image_picker_ABC123.jpg');
      await CameraCache(dir, ios: true).clean();
      expect(_exists(dir, _androidOwned('3')), isTrue);
      expect(_exists(dir, 'image_picker_ABC123.jpg'), isFalse);
      _touch(dir, 'image_picker_ABC123.jpg');
      await CameraCache(dir, ios: false).clean();
      expect(_exists(dir, 'image_picker_ABC123.jpg'), isTrue);
    });

    test('iOS accepts jpg/jpeg/png/heic owned names', () async {
      for (final name in [
        'image_picker_a1.jpg',
        'image_picker_b2.JPEG',
        'image_picker_c3.png',
        'image_picker_d4.heic',
      ]) {
        _touch(dir, name);
      }
      _touch(dir, 'image_picker_e5.bmp');
      await CameraCache(dir, ios: true).clean();
      expect(_exists(dir, 'image_picker_a1.jpg'), isFalse);
      expect(_exists(dir, 'image_picker_b2.JPEG'), isFalse);
      expect(_exists(dir, 'image_picker_c3.png'), isFalse);
      expect(_exists(dir, 'image_picker_d4.heic'), isFalse);
      expect(_exists(dir, 'image_picker_e5.bmp'), isTrue);
    });

    test(
      'root alias: symlinked root spelling still cleans owned files',
      () async {
        // Regression for macOS /var vs /private/var: the configured root may
        // be spelled through a symlink. Legitimate owned files must still be
        // cleaned via their resolved canonical path.
        final real = Directory('${dir.path}${Platform.pathSeparator}real')
          ..createSync();
        final aliasPath = '${dir.path}${Platform.pathSeparator}alias-root';
        Link(aliasPath).createSync(real.path);
        _touch(real, _androidOwned('20'));
        _touch(real, 'keep.txt');
        await CameraCache(Directory(aliasPath), ios: false).clean();
        expect(_exists(real, _androidOwned('20')), isFalse);
        expect(_exists(real, 'keep.txt'), isTrue);
      },
    );
  });

  group('interrupted copies', () {
    test(
      'clean removes partial/empty owned files and still finishes',
      () async {
        _touch(dir, _androidOwned('5'), []); // zero bytes: crashed mid-write
        _touch(dir, _androidOwned('6'), [0xFF]); // single partial byte
        _touch(dir, 'notes.txt', [9]);
        await CameraCache(dir, ios: false).clean();
        expect(_exists(dir, _androidOwned('5')), isFalse);
        expect(_exists(dir, _androidOwned('6')), isFalse);
        expect(_exists(dir, 'notes.txt'), isTrue);
      },
    );
  });

  group('external original preservation', () {
    test('remove refuses paths outside the root, even owned-looking', () async {
      final name = _androidOwned('8');
      _touch(outside, name);
      final helper = CameraCache(dir, ios: false);
      await helper.remove('${outside.path}${Platform.pathSeparator}$name');
      expect(_exists(outside, name), isTrue);
    });

    test('remove refuses .. traversal back outside the root', () async {
      final name = _androidOwned('9');
      _touch(outside, name);
      final helper = CameraCache(dir, ios: false);
      await helper.remove(
        '${dir.path}${Platform.pathSeparator}sub'
        '${Platform.pathSeparator}..${Platform.pathSeparator}..'
        '${Platform.pathSeparator}${outside.path.split(Platform.pathSeparator).last}'
        '${Platform.pathSeparator}$name',
      );
      expect(_exists(outside, name), isTrue);
    });

    test(
      'remove deletes an owned direct child, ignores missing paths',
      () async {
        final helper = CameraCache(dir, ios: false);
        _touch(dir, _androidOwned('10'));
        await helper.remove(
          '${dir.path}${Platform.pathSeparator}${_androidOwned('10')}',
        );
        expect(_exists(dir, _androidOwned('10')), isFalse);
        await helper.remove(
          '${dir.path}${Platform.pathSeparator}${_androidOwned('zzz-missing')}',
        );
      },
    );

    test('remove keeps nested owned files (direct children only)', () async {
      final sub = Directory('${dir.path}${Platform.pathSeparator}sub')
        ..createSync();
      _touch(sub, _androidOwned('11'));
      await CameraCache(
        dir,
        ios: false,
      ).remove('${sub.path}${Platform.pathSeparator}${_androidOwned('11')}');
      expect(_exists(sub, _androidOwned('11')), isTrue);
    });
  });

  group('unrelated files', () {
    test('clean keeps vault/index and app files', () async {
      for (final name in ['index.enc', 'notes.txt', 'model.litertlm']) {
        _touch(dir, name);
      }
      _touch(dir, _androidOwned('12'));
      await CameraCache(dir, ios: false).clean();
      expect(_exists(dir, 'index.enc'), isTrue);
      expect(_exists(dir, 'notes.txt'), isTrue);
      expect(_exists(dir, 'model.litertlm'), isTrue);
      expect(_exists(dir, _androidOwned('12')), isFalse);
    });

    test('clean on a missing directory is a silent no-op', () async {
      final gone = Directory('${dir.path}${Platform.pathSeparator}nope');
      await CameraCache(gone, ios: false).clean();
    });
  });

  group('symlink guard', () {
    test('clean never follows links, even owned-looking ones', () async {
      final target = File('${outside.path}${Platform.pathSeparator}secret.jpg')
        ..writeAsBytesSync([7, 7, 7], flush: true);
      Link(
        '${dir.path}${Platform.pathSeparator}${_androidOwned('13')}',
      ).createSync(target.path);
      await CameraCache(dir, ios: false).clean();
      expect(target.existsSync(), isTrue);
      expect(
        Link(
          '${dir.path}${Platform.pathSeparator}${_androidOwned('13')}',
        ).existsSync(),
        isTrue,
      );
    });

    test('remove refuses symlink paths without touching target', () async {
      final target = File('${outside.path}${Platform.pathSeparator}secret2.jpg')
        ..writeAsBytesSync([8], flush: true);
      final linkPath =
          '${dir.path}${Platform.pathSeparator}${_androidOwned('14')}';
      Link(linkPath).createSync(target.path);
      await CameraCache(dir, ios: false).remove(linkPath);
      expect(target.existsSync(), isTrue);
      expect(Link(linkPath).existsSync(), isTrue);
    });
  });
}
