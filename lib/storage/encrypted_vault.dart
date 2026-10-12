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
