import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Deletes ONLY owned image-picker cache files. Never originals, never
/// unrelated caches, never anything reached through a symlink.
///
/// Scope (board MSG-033):
/// - Android: image_picker_android 0.8.13+25
///   `ImagePickerDelegate.createTemporaryWritableFile` creates
///   `File.createTempFile(UUID().toString(), .jpg, activity.cacheDir)` —
///   i.e. UUID + numeric suffix + `.jpg`, regular files directly under the
///   cache dir. Root here is `getTemporaryDirectory()`.
/// - iOS: `FLTImagePickerPhotoAssetUtil` owned names
///   `image_picker_*.(jpg|jpeg|png|heic)`. Root here is the privacy channel's
///   `getTemporaryRoot` (native side owned by Main).
///
/// Every deletion is gated by canonical-root containment + direct-child +
/// known-plugin-filename + regular-file (never follow links). `clean()` is
/// for startup; `remove()` for finally/cancel paths. Both never throw:
/// startup and cancellation cleanup must not block or crash the app.
/// Main integrates, preserves camera originals into the vault, and owns the
/// native `getTemporaryRoot` wiring.
class CameraCache {
  CameraCache(Directory root, {required this.ios})
    : _root = Directory(_normalize(root.absolute.path));

  final Directory _root;
  final bool ios;

  /// Android: cache dir. iOS: privacy-channel temporary root.
  static Future<CameraCache> forDevice() async {
    if (Platform.isIOS) {
      const channel = MethodChannel('app.ayumitra/privacy');
      final root = await channel.invokeMethod<String>('getTemporaryRoot');
      if (root == null || root.isEmpty) {
        throw StateError('iOS temporary root is unavailable.');
      }
      return CameraCache(Directory(root), ios: true);
    }
    return CameraCache(await getTemporaryDirectory(), ios: false);
  }

  /// Startup sweep: delete owned plugin files directly under root.
  /// Continues past per-file errors; never deletes directories, links,
  /// nested files, or anything outside the owned patterns.
  Future<void> clean() async {
    List<FileSystemEntity> entries;
    try {
      entries = _root.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      try {
        // The listing does not follow links, so symlink leaves (even
        // owned-looking ones) arrive as Link and are skipped unread.
        if (entity is! File) continue;
        final resolved = _scopedFile(_normalize(entity.absolute.path));
        if (resolved == null) continue;
        File(resolved).deleteSync();
      } catch (_) {
        // Startup cleanup never blocks on one bad entry.
      }
    }
  }

  /// Single-file cleanup for finally/cancel paths. No-op (never throws) when
  /// the path is outside the root, not a direct child, not a regular file,
  /// not an owned plugin filename, or reached through a symlink.
  Future<void> remove(String path) async {
    try {
      final resolved = _scopedFile(_normalize(path));
      if (resolved == null) return;
      File(resolved).deleteSync();
    } catch (_) {
      // Cancellation cleanup never throws.
    }
  }

  /// Full scope gate. The initial direct-child check accepts the configured
  /// root spelling OR its canonical form (macOS /var vs /private/var
  /// aliases); the file is then resolved and its real parent must equal the
  /// canonical root. Symlink leaves are never followed: anything that is not
  /// a regular file at check time is refused, and the resolved path is
  /// re-checked before deletion.
  String? _scopedFile(String abs) {
    if (!_isDirectChild(abs) || !_isOwnedName(_basename(abs))) return null;
    return _resolveFile(abs);
  }

  String? _resolveFile(String abs) {
    try {
      if (FileSystemEntity.typeSync(abs, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final resolved = _normalize(File(abs).resolveSymbolicLinksSync());
      if (_parent(resolved) != _canonicalRoot) return null;
      if (FileSystemEntity.typeSync(resolved, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      return resolved;
    } catch (_) {
      return null;
    }
  }

  // UUID (36 chars incl. dashes) + Java createTempFile numeric suffix + .jpg.
  static final _androidOwned = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[0-9]+\.jpg$',
  );

  // FLTImagePickerPhotoAssetUtil owned names.
  static final _iosOwned = RegExp(
    r'^image_picker_[A-Za-z0-9_.\-]+\.(jpg|jpeg|png|heic)$',
    caseSensitive: false,
  );

  bool _isOwnedName(String name) =>
      ios ? _iosOwned.hasMatch(name) : _androidOwned.hasMatch(name);

  String get _canonicalRoot {
    try {
      return _normalize(_root.resolveSymbolicLinksSync());
    } catch (_) {
      return _root.path;
    }
  }

  bool _isDirectChild(String abs) {
    final parent = _parent(abs);
    return parent == _root.path || parent == _canonicalRoot;
  }

  /// Lexical normalization (resolves `.`/`..` without touching the fs, so
  /// `..` traversal can never escape the root check). Never follows links.
  static String _normalize(String path) {
    var p = path.replaceAll(RegExp(r'[\\/]+'), Platform.pathSeparator);
    final isAbs =
        p.startsWith(Platform.pathSeparator) ||
        RegExp(r'^[A-Za-z]:\\').hasMatch(path);
    final parts = <String>[];
    for (final seg in p.split(Platform.pathSeparator)) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    final joined = parts.join(Platform.pathSeparator);
    if (isAbs) return Platform.pathSeparator + joined;
    return joined.isEmpty ? '.' : joined;
  }

  static String _basename(String abs) {
    final i = abs.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? abs : abs.substring(i + 1);
  }

  static String _parent(String abs) {
    final i = abs.lastIndexOf(Platform.pathSeparator);
    if (i <= 0) return abs;
    return abs.substring(0, i);
  }
}
