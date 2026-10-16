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
  'account_alias',
  'classification_history',
  'learning_example',
  'notif_feedback',
  'notif_mute',
  'auto_pattern',
  'auto_observation',
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
  'settlement_extra',
  'group_preset',
  'budget',
];
const _skipKv = {
  'lock_hash',
  'lock_salt',
  'lock_bio',
  'lock_delay',
  'last_backup_at',
};

Future<Map<String, Object?>> exportData(Database db) async {
  final out = <String, Object?>{
    'version': 1,
    'exported_at': DateTime.now().toIso8601String(),
  };
  for (final t in _tables) {
    out[t] = await db.query(t);
  }
  final kv = await db.query('kv');
  out['kv'] = kv.where((r) => !_skipKv.contains(r['k'])).toList();
  return out;
}

Future<Uint8List> encryptBackup(
  Map<String, Object?> data,
  String passphrase,
) async {
  final plain = GZipCodec().encode(utf8.encode(jsonEncode(data)));
  final rnd = SecretKeyData.random(length: 28).bytes;
  final salt = rnd.sublist(0, 16), nonce = rnd.sublist(16);
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: key,
    nonce: nonce,
  );
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

Future<Map<String, Object?>> decryptBackup(
  Uint8List file,
  String passphrase,
) async {
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
    return jsonDecode(utf8.decode(GZipCodec().decode(plain)))
        as Map<String, Object?>;
  } on SecretBoxAuthenticationError {
    throw BackupError('암호가 맞지 않거나 파일이 손상됐어요');
  }
}

/// 병합 복원: 같은 id의 거래는 updated_at이 더 큰 쪽을 남기고, 나머지 테이블은 새 행만 추가한다.
/// 반환값은 새로 들어온 거래 수.
Future<int> importData(Database db, Map<String, Object?> data) async {
  var added = 0;
  await db.transaction((t) async {
    // 다른 기기에서 같은 은행 계좌를 새 key로 등록한 백업도 하나의 통장으로 합친다.
    final existingAccounts = await t.query('account');
    final byKey = {for (final row in existingAccounts) row['key']: row};
    final identities = <String, String>{
      for (final row in existingAccounts)
        if (row['bank_code'] != null && row['account_number'] != null)
          '${row['bank_code']}:${row['account_number']}': row['key'] as String,
    };
    final accountMap = <String, String>{};
    for (final row
        in (data['account'] as List?)?.cast<Map<String, Object?>>() ??
            const []) {
      if (row['bank_code'] == null || row['account_number'] == null) continue;
      final key = row['key'] as String;
      final identity = '${row['bank_code']}:${row['account_number']}';
      final same = identities[identity];
      if (same != null && same != key) {
        accountMap[key] = same;
        continue;
      }
      final current = byKey[key];
      if (current != null &&
          current['bank_code'] != null &&
          (current['bank_code'] != row['bank_code'] ||
              current['account_number'] != row['account_number'])) {
        throw BackupError('서로 다른 계좌 정보가 충돌해 복원을 중단했어요. 기존 데이터는 유지됩니다.');
      }
      identities[identity] = key;
    }
    Map<String, Object?> remapSample(Map<String, Object?> sample) {
      if (sample['input_json'] is! String || accountMap.isEmpty) return sample;
      final input =
          jsonDecode(sample['input_json'] as String) as Map<String, dynamic>;
      for (final field in ['account', 'destination']) {
        input[field] = accountMap[input[field]] ?? input[field];
      }
      return {...sample, 'input_json': jsonEncode(input)};
    }

    for (final name in _tables) {
      final rows =
          (data[name] as List?)?.cast<Map<String, Object?>>() ?? const [];
      for (final original in rows) {
        var r = Map<String, Object?>.from(original);
        final fields = switch (name) {
          'tx' => ['account', 'destination'],
          'account' => ['key', 'pays_from'],
          'account_alias' => ['canonical'],
          'allocation' => ['from_key', 'to_key'],
          'gap_alert' => ['account'],
          'auto_pattern' => ['destination'],
          _ => <String>[],
        };
        for (final field in fields) {
          if (r.containsKey(field)) r[field] = accountMap[r[field]] ?? r[field];
        }
        if (name == 'account_alias' && r['alias'] == r['canonical']) continue;
        if (name == 'learning_example') r = remapSample(r);
        if(name=='tx'&&r['auto_pair_before'] is String){
          final snapshot=jsonDecode(r['auto_pair_before'] as String) as Map<String,dynamic>;
          for(final field in ['before','after']){final value=Map<String,dynamic>.from(snapshot[field] as Map);value['destination']=accountMap[value['destination']]??value['destination'];snapshot[field]=value;}
          r['auto_pair_before']=jsonEncode(snapshot);
        }
        if(name=='auto_observation'){
          final proposed=jsonDecode(r['proposed_json'] as String) as Map<String,dynamic>;
          proposed['destination']=accountMap[proposed['destination']]??proposed['destination'];
          r['proposed_json']=jsonEncode(proposed);
        }
        if (name == 'classification_history') {
          for(final field in ['before_json','after_json']){
            final value=jsonDecode(r[field] as String) as Map<String,dynamic>;
            for(final key in ['account','destination']){if(value.containsKey(key))value[key]=accountMap[value[key]]??value[key];}
            r[field]=jsonEncode(value);
          }
          for (final field in ['sample_before', 'sample_after']) {
            if (r[field] is String) {
              r[field] = jsonEncode(
                remapSample(
                  jsonDecode(r[field] as String) as Map<String, dynamic>,
                ),
              );
            }
          }
        }
        if (name == 'tx' || name == 'learning_example') {
          final idColumn = name == 'tx' ? 'id' : 'tx_id';
          final cur = await t.query(
            name,
            where: '$idColumn=?',
            whereArgs: [r[idColumn]],
          );
          if (cur.isEmpty) {
            await t.insert(name, r);
            if (name == 'tx') added++;
          } else if (((r['updated_at'] as int?) ?? 0) >
              ((cur.first['updated_at'] as int?) ?? 0)) {
            await t.insert(
              name,
              r,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        } else {
          if(name=='auto_pattern'||name=='auto_observation'){
            final id=name=='auto_pattern'?'pattern_key':'tx_id';
            final revision=name=='auto_pattern'?'updated_at':'decided_at';
            final current=await t.query(name,where:'$id=?',whereArgs:[r[id]]);
            if(name=='auto_pattern'&&r['enabled']==1)r['enabled']=2; // 복원한 자동 반영은 범위를 다시 확인한 뒤 켠다.
            if(current.isEmpty||((r[revision] as int?)??0)>((current.single[revision] as int?)??0)){
              await t.insert(name,r,conflictAlgorithm:ConflictAlgorithm.replace);
            }
            continue;
          }
          if(name=='notif_mute'){
            final current=await t.query(name,where:'package=? AND title=?',whereArgs:[r['package'],r['title']]);
            int revision(Map<String,Object?> value){
              final created=(value['created_at'] as int?)??0,removed=(value['removed_at'] as int?)??0;
              return created>removed?created:removed;
            }
            if(current.isEmpty || revision(r)>revision(current.single)){
              await t.insert(name,r,conflictAlgorithm:ConflictAlgorithm.replace);
            }
            continue;
          }
          if(name=='notif_feedback'){
            r['raw_id']=null;
            final current=await t.query(name,where:'notification_key=?',whereArgs:[r['notification_key']]);
            if(current.isEmpty || ((r['at'] as int?)??0)>((current.single['at'] as int?)??0)){
              await t.insert(name,r,conflictAlgorithm:ConflictAlgorithm.replace);
            }
            continue;
          }
          if (name == 'account' &&
              byKey[r['key']]?['bank_code'] == null &&
              r['bank_code'] != null &&
              byKey.containsKey(r['key'])) {
            await t.update(
              'account',
              {
                'bank_code': r['bank_code'],
                'account_number': r['account_number'],
              },
              where: 'key=?',
              whereArgs: [r['key']],
            );
          }
          await t.insert(name, r, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    }
    for (final r
        in (data['kv'] as List?)?.cast<Map<String, Object?>>() ?? const []) {
      // 설정은 이 기기 값을 우선한다.
      await t.insert('kv', r, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  });
  return added;
}
