import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/records.dart';

/// All health-bearing persistence, including the index, is authenticated ciphertext.
/// The caller obtains the key from platform secure storage; never recreate a lost key.
class EncryptedVault {
  EncryptedVault({required this.directory, required this.key});
  final Directory directory;
  final SecretKey key;
  final _cipher = AesGcm.with256bits();
  final _lock = Lock();
  File get _index => File('${directory.path}/index.enc');

  Future<Uint8List> seal(List<int> plain, String purpose) async {
    final box = await _cipher.encrypt(
      plain,
      secretKey: key,
      aad: utf8.encode(purpose),
    );
    return Uint8List.fromList(box.concatenation());
  }

  Future<Uint8List> unseal(List<int> bytes, String purpose) async =>
      Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
          secretKey: key,
          aad: utf8.encode(purpose),
        ),
      );

  Future<VaultData> read() async {
    await directory.create(recursive: true);
    if (!await _index.exists()) return const VaultData();
    return VaultData.decode(
      utf8.decode(
        await unseal(await _index.readAsBytes(), 'ayumitra:index:v1'),
      ),
    );
  }

  Future<void> save(VaultData data) => _lock.synchronized(() async {
    await directory.create(recursive: true);
    final encrypted = await seal(
      utf8.encode(jsonEncode(data.toJson())),
      'ayumitra:index:v1',
    );
    final staging = File('${_index.path}.new');
    await staging.writeAsBytes(encrypted, flush: true);
    await staging.rename(_index.path);
  });

  /// Finish only logically deleted profiles. Persist the tombstones before
  /// calling, then persist this returned snapshot; an interrupted cleanup is
  /// safe to retry. A filesystem failure leaves that profile queued.
  Future<VaultData> completeProfileDeletions(VaultData data) =>
      _lock.synchronized(() async {
        final pending = <String>[];
        for (final id in data.deletedProfileIds.toSet()) {
          final stillOwned =
              data.profiles.any((profile) => profile.id == id) ||
              data.reports.any((report) => report.profileId == id) ||
              data.sessions.any((session) => session.profileId == id) ||
              data.memories.any((memory) => memory.profileId == id) ||
              data.exports.any((entry) => entry.profileId == id);
          if (stillOwned) {
            pending.add(id);
            continue;
          }
          try {
            await _eraseProfileOriginals(id);
          } on FileSystemException {
            pending.add(id);
          } on StateError {
            pending.add(id);
          }
        }
        return data.copy(deletedProfileIds: pending);
      });

  Future<void> _eraseProfileOriginals(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
      throw StateError('Invalid profile identity.');
    }
    final rootType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.notFound) return;
    if (rootType != FileSystemEntityType.directory) {
      throw StateError('Vault directory is not a regular directory.');
    }
    // Resolve trusted OS aliases above the vault (for example /var on macOS).
    // The vault itself and every owned descendant must not be symbolic links.
    final canonicalRoot = await directory.resolveSymbolicLinks();
    final originals = Directory('$canonicalRoot/originals');
    final originalsType = await FileSystemEntity.type(
      originals.path,
      followLinks: false,
    );
    if (originalsType == FileSystemEntityType.notFound) return;
    if (originalsType != FileSystemEntityType.directory) {
      throw StateError('Originals directory is not a regular directory.');
    }
    if (await originals.resolveSymbolicLinks() != originals.path) {
      throw StateError('Originals directory is outside the vault.');
    }
    final target = Directory('${originals.path}/$id');
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.notFound) return;
    if (targetType != FileSystemEntityType.directory ||
        await target.resolveSymbolicLinks() != target.path) {
      throw StateError('Profile originals are not a regular owned directory.');
    }
    // Refuse the whole cleanup before deleting anything if a descendant is a
    // symlink. Never follow links into a different profile or model directory.
    await for (final entry in target.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw StateError(
          'Profile originals contain an unsafe filesystem entry.',
        );
      }
    }
    await target.delete(recursive: true);
  }

  Future<void> saveOriginal(Report report, Uint8List bytes) async {
    final target = _original(report);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(await seal(bytes, _purpose(report)), flush: true);
  }

  Future<Uint8List> readOriginal(Report report, String activeProfileId) async {
    if (report.profileId != activeProfileId) {
      throw StateError('Profile access denied.');
    }
    return unseal(await _original(report).readAsBytes(), _purpose(report));
  }

  File _original(Report r) {
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(r.id) ||
        !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(r.profileId)) {
      throw StateError('Invalid record identity.');
    }
    return File('${directory.path}/originals/${r.profileId}/${r.id}.enc');
  }

  String _purpose(Report r) => 'ayumitra:original:v1:${r.profileId}:${r.id}';
}
