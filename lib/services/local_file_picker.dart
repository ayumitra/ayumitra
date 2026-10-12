import 'dart:io';
import 'package:cross_file/cross_file.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// iOS imports into our dedicated cache, never the plugin's shared temp folder.
bool _picking = false;
Future<PlatformFile?> pickLocalFile(List<String> extensions) async {
  if (_picking) return null;
  _picking = true;
  try {
    if (!Platform.isIOS) {
      return FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
    }
    final result = await const MethodChannel(
      'app.ayumitra/picker',
    ).invokeMapMethod<String, String>('pick');
    final path = result?['path'];
    if (path == null) return null;
    return NativePickedFile(path);
  } finally {
    _picking = false;
  }
}

class PickerCache {
  PickerCache(this.roots);
  final List<Directory> roots;

  static Future<PickerCache> forDevice() async {
    final temporary = await getTemporaryDirectory();
    return PickerCache([
      Directory('${temporary.path}/ayumitra-picker'),
      if (Platform.isAndroid) Directory('${temporary.path}/file_picker'),
    ]);
  }

  Future<void> clean() async {
    for (final root in roots) {
      if (await root.exists()) await root.delete(recursive: true);
    }
  }

  Future<void> remove(PlatformFile file) async {
    if (file.uri.scheme != 'file') return;
    final picked = File.fromUri(file.uri);
    if (!await picked.exists()) return;
    final resolved = await picked.resolveSymbolicLinks();
    for (final root in roots) {
      if (!await root.exists()) continue;
      final owned = await root.resolveSymbolicLinks();
      if (resolved.startsWith('$owned${Platform.pathSeparator}')) {
        await picked.delete();
        return;
      }
    }
    // External originals are never deleted.
  }
}

final class NativePickedFile extends PlatformFile {
  NativePickedFile(String path) : _file = File(path);
  final File _file;
  @override
  String get name => _file.uri.pathSegments.last;
  @override
  Uri get uri => _file.uri;
  @override
  XFile get xFile => XFile(_file.path);
  @override
  int? lengthSync() => _file.lengthSync();
  @override
  Future<int?> length() => _file.length();
  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      _file.openRead().map(Uint8List.fromList);
}
