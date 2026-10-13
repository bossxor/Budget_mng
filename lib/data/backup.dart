import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

/// 암호화 백업: JSON -> gzip -> AES-256-GCM (키는 암호에서 PBKDF2로 유도).
/// 파일 구조: "JMBAK1" | salt(16) | nonce(12) | ciphertext | mac(16)
///
/// 백업에 넣지 않는 것: 알림 원문(개인정보, 용량), PIN 해시/솔트(다른 기기로 옮기면 안 되는 값).
const _magic = 'JMBAK1';
const _iterations = 60000;

const _tables = [
  'tx',
  'account',
  'rule',
  'person',
  'settlement',
  'settlement_item',
  'settlement_share',
  'settlement_payment',
  'allocation',
  'tx_tag',
  'tx_split',
  'gap_alert',
];
const _skipKv = {'lock_hash', 'lock_salt', 'lock_bio', 'lock_delay', 'last_backup_at'};

Future<Map<String, Object?>> exportData(Database db) async {
  final out = <String, Object?>{'version': 1, 'exported_at': DateTime.now().toIso8601String()};
  for (final t in _tables) {
    out[t] = await db.query(t);
  }
  final kv = await db.query('kv');
  out['kv'] = kv.where((r) => !_skipKv.contains(r['k'])).toList();
  return out;
}

Future<Uint8List> encryptBackup(Map<String, Object?> data, String passphrase) async {
  final plain = GZipCodec().encode(utf8.encode(jsonEncode(data)));
  final rnd = SecretKeyData.random(length: 28).bytes;
  final salt = rnd.sublist(0, 16), nonce = rnd.sublist(16);
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  final box = await AesGcm.with256bits().encrypt(plain, secretKey: key, nonce: nonce);
  return Uint8List.fromList([
    ...utf8.encode(_magic),
    ...salt,
    ...nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

class BackupError implements Exception {
  BackupError(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<Map<String, Object?>> decryptBackup(Uint8List file, String passphrase) async {
  final head = utf8.encode(_magic).length;
  if (file.length < head + 16 + 12 + 16 ||
      utf8.decode(file.sublist(0, head), allowMalformed: true) != _magic) {
    throw BackupError('주머니 백업 파일이 아니에요');
  }
  final salt = file.sublist(head, head + 16);
  final nonce = file.sublist(head + 16, head + 28);
  final cipher = file.sublist(head + 28, file.length - 16);
  final mac = file.sublist(file.length - 16);
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  try {
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return jsonDecode(utf8.decode(GZipCodec().decode(plain))) as Map<String, Object?>;
  } on SecretBoxAuthenticationError {
    throw BackupError('암호가 맞지 않거나 파일이 손상됐어요');
  }
}

/// 병합 복원: 같은 id의 거래는 updated_at이 더 큰 쪽을 남기고, 나머지 테이블은 새 행만 추가한다.
/// 반환값은 새로 들어온 거래 수.
Future<int> importData(Database db, Map<String, Object?> data) async {
  var added = 0;
  await db.transaction((t) async {
    for (final name in _tables) {
      final rows = (data[name] as List?)?.cast<Map<String, Object?>>() ?? const [];
      for (final r in rows) {
        if (name == 'tx') {
          final cur = await t.query('tx', where: 'id=?', whereArgs: [r['id']]);
          if (cur.isEmpty) {
            await t.insert('tx', r);
            added++;
          } else if (((r['updated_at'] as int?) ?? 0) >
              ((cur.first['updated_at'] as int?) ?? 0)) {
            await t.insert('tx', r, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        } else {
          await t.insert(name, r, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }
    for (final r in (data['kv'] as List?)?.cast<Map<String, Object?>>() ?? const []) {
      // 설정은 이 기기 값을 우선한다.
      await t.insert('kv', r, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  });
  return added;
}
