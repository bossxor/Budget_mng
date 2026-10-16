part of 'repo.dart';

const transferPurposes = ['내 계좌 이체', '생활비 이동', '적금', '여행저축', '비상금', '카드대금'];

Future<void> addColumnSafely(Database db,String table,String column) async {
  try { await db.execute('ALTER TABLE $table ADD COLUMN $column'); }
  on DatabaseException catch(error) {
    if(!error.toString().toLowerCase().contains('duplicate column name')) rethrow;
  }
}
Future<void> ensureAccountTools(Database db) async {
  await db.execute('CREATE TABLE IF NOT EXISTS account_alias(alias TEXT PRIMARY KEY, canonical TEXT NOT NULL)');
  await db.execute('CREATE TABLE IF NOT EXISTS classification_history(id TEXT PRIMARY KEY, tx_id TEXT, before_json TEXT, after_json TEXT, keyword TEXT, rule_before TEXT, rule_after TEXT, created_at INTEGER, undone INTEGER DEFAULT 0)');
  final historyColumns = await db.rawQuery('PRAGMA table_info(classification_history)');
  if (!historyColumns.any((c) => c['name']=='batch')) await addColumnSafely(db,'classification_history','batch TEXT');
  for (final column in ['pair_id TEXT', 'destination TEXT']) {
    final columns = await db.rawQuery('PRAGMA table_info(tx)');
    if (!columns.any((c) => c['name'] == column.split(' ').first)) await addColumnSafely(db,'tx',column);
  }
  for (final column in ['manual_balance INTEGER', 'manual_balance_at INTEGER']) {
    final columns = await db.rawQuery('PRAGMA table_info(account)');
    if (!columns.any((c) => c['name'] == column.split(' ').first)) await addColumnSafely(db,'account',column);
  }
}

/// 전체 내역에서는 한 이체의 출금·입금 원문을 하나로 표시한다. 통장 필터에서는 해당 쪽을 유지한다.
List<TxRow> collapseTransfers(List<TxRow> rows) {
  final ids = rows.map((r) => r.id).toSet();
  return rows.where((r) => !(r.type == 'transfer' && r.direction == 'in' && r.pairId != null && ids.contains(r.pairId))).toList();
}

extension AccountTools on Repo {
  Future<String?> resolveAccount(String? key) async {
    if (key == null) return null;
    final aliases = await _db.query('account_alias', where: 'alias=?', whereArgs: [key]);
    return aliases.isEmpty ? (await _registeredAccount(key))??key : aliases.first['canonical'] as String;
  }

  Future<void> linkAccount(String source, String target) async {
    final dest = (await resolveAccount(target))!;
    if (source == dest) throw ArgumentError('같은 통장은 연결할 수 없어요');
    await _db.transaction((db) async {
      for (final key in [source, dest]) {
        if ((await db.query('account', where: 'key=?', whereArgs: [key])).isEmpty) throw ArgumentError('등록된 통장을 선택하세요');
      }
      final sourceRow=(await db.query('account',where:'key=?',whereArgs:[source])).first;
      final targetRow=(await db.query('account',where:'key=?',whereArgs:[dest])).first;
      if(sourceRow['bank_code']!=null && sourceRow['account_number']!=null) {
        if(targetRow['bank_code']!=null &&
          (targetRow['bank_code']!=sourceRow['bank_code'] || targetRow['account_number']!=sourceRow['account_number'])) {
          throw ArgumentError('은행·계좌번호가 다른 통장은 연결할 수 없어요.');
        }
        await db.update('account',{'bank_code':null,'account_number':null},where:'key=?',whereArgs:[source]);
        await db.update('account',{'bank_code':sourceRow['bank_code'],'account_number':sourceRow['account_number']},where:'key=?',whereArgs:[dest]);
      }
      if ((sourceRow['manual_balance_at'] as int? ?? -1) > (targetRow['manual_balance_at'] as int? ?? -1)) {
        await db.update('account',{'manual_balance':sourceRow['manual_balance'],'manual_balance_at':sourceRow['manual_balance_at']},where:'key=?',whereArgs:[dest]);
      }
      await db.insert('account_alias', {'alias': source, 'canonical': dest}, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.update('account_alias', {'canonical': dest}, where: 'canonical=?', whereArgs: [source]);
      await db.update('tx', {'account': dest}, where: 'account=?', whereArgs: [source]);
      await db.update('tx', {'destination': dest}, where: 'destination=?', whereArgs: [source]);
      await db.update('allocation', {'from_key': dest}, where: 'from_key=?', whereArgs: [source]);
      await db.update('allocation', {'to_key': dest}, where: 'to_key=?', whereArgs: [source]);
      await db.update('account', {'pays_from': dest}, where: 'pays_from=?', whereArgs: [source]);
      await db.update('gap_alert', {'account': dest}, where: 'account=?', whereArgs: [source]);
    });
    await pairTransfers();
  }

  Future<void> correctBalance(String key, int? balance, DateTime at) async {
    if (at.isAfter(DateTime.now())) throw ArgumentError('미래 날짜로 잔액을 보정할 수 없어요');
    await _db.update('account', {'manual_balance': balance, 'manual_balance_at': balance == null ? null : at.millisecondsSinceEpoch}, where: 'key=?', whereArgs: [key]);
  }

  Future<void> classifyTx(String id, {String? type, String? category,
      String? expectedSuggestion, String? expectedRecommendedType,
      String? expectedRecommendedCategory}) async {
    await migratePersonalApprovals();
    await _db.transaction((db) async {
      final first=(await db.query('tx',where:'id=? AND deleted_at IS NULL',whereArgs:[id])).first;
      if(['candidate','rejected'].contains(first['status']))throw StateError('알림이 실제 거래인지 먼저 확인해 주세요.');
      if (expectedSuggestion != null) {
        final suggestion=await db.query('learning_suggestion',where:'tx_id=?',whereArgs:[id]);
        if (suggestion.isEmpty || suggestion.first['fingerprint']!=expectedSuggestion ||
            _learningFingerprint(first)!=expectedSuggestion ||
            (expectedRecommendedType!=null &&
              (suggestion.first['type']!=expectedRecommendedType ||
                suggestion.first['category']!=expectedRecommendedCategory))) {
          throw StateError('거래가 변경되었어요. 최신 추천을 다시 확인해 주세요.');
        }
      }
      if(type!=null && !['expense','income','transfer','group'].contains(type)) throw ArgumentError('거래 종류를 확인하세요');
      if(first['pair_id']!=null && type!=null && type!='transfer') throw ArgumentError('연결된 이체의 목적만 변경할 수 있어요');
      final ids=[id, if(first['pair_id']!=null && category!=null)first['pair_id'] as String];
      final batch=_newId();
      for(final key in ids) {
        await pauseAutoForTx(db,key);
        final found=await db.query('tx',where:'id=? AND deleted_at IS NULL',whereArgs:[key]);
        if(found.isEmpty) continue;
        final current=found.first;
        final before={for(final name in ['type','category','status','memo','dir','auto_applied_key'])name:current[name]};
        final after={...before,'status':'ok','memo':null,'auto_applied_key':null};
        if(type!=null) { after['type']=type; }
        if(category!=null) { after['category']=category; }
        if(type=='transfer' && current['type']!='transfer') after['dir']=current['type']=='income'?'in':'out';
        final rawKeyword=(current['merchant']??current['counterparty']) as String?;
        final keyword=category!=null && after['type']=='expense' && rawKeyword!=null && !['(알 수 없음)','출금·결제','입금','현금'].contains(rawKeyword)?rawKeyword:null;
        final rules=keyword==null?<Map<String,Object?>>[]:await db.query('rule',where:'keyword=?',whereArgs:[keyword]);
        final previousSamples=await db.query('learning_example',where:'tx_id=?',whereArgs:[key]);
        await db.delete('learning_example',where:'tx_id=?',whereArgs:[key]);
        final sample=await _rememberApproval(db,{...current,...after});
        await db.insert('classification_history',{'id':_newId(),'batch':batch,'tx_id':key,'before_json':jsonEncode(before),'after_json':jsonEncode(after),'keyword':keyword,'rule_before':rules.isEmpty?null:rules.first['category'],'rule_after':keyword==null?null:category,'created_at':DateTime.now().microsecondsSinceEpoch,
          'sample_before':previousSamples.isEmpty?null:jsonEncode(previousSamples.first),
          'sample_after':sample==null?null:jsonEncode(sample)});
        await db.delete('learning_suggestion',where:'tx_id=?',whereArgs:[key]);
        await db.update('tx',{...after,'updated_at':DateTime.now().millisecondsSinceEpoch},where:'id=?',whereArgs:[key]);
        if(keyword!=null) await db.insert('rule',{'keyword':keyword,'category':category},conflictAlgorithm:ConflictAlgorithm.replace);
      }
    });
  }

  Future<bool> undoClassification(String id) async => _db.transaction((db) async {
    final latest=await db.query('classification_history',where:'tx_id=? AND undone=0',whereArgs:[id],orderBy:'created_at DESC',limit:1);
    if(latest.isEmpty) return false;
    final h=latest.first;
    final changes=h['batch']==null?latest:await db.query('classification_history',where:'batch=? AND undone=0',whereArgs:[h['batch']]);
    for(final change in changes) {
      final current=await db.query('tx',where:'id=? AND deleted_at IS NULL',whereArgs:[change['tx_id']]);
      final after=jsonDecode(change['after_json'] as String) as Map<String,dynamic>;
      final before=jsonDecode(change['before_json'] as String) as Map<String,dynamic>;
      final autoPair=current.isNotEmpty&&current.first['auto_pair_before']!=null&&current.first['auto_applied_key']!=null;
      if (current.isNotEmpty && current.first['pair_id'] != null && before['type'] != 'transfer'&&!autoPair) return false;
      if(current.isEmpty || after.entries.any((e)=>!(autoPair&&e.key=='destination')&&current.first[e.key]!=e.value)) return false;
      if(autoPair){
        final snapshot=jsonDecode(current.first['auto_pair_before'] as String) as Map<String,dynamic>;
        final partner=await db.query('tx',where:'id=? AND deleted_at IS NULL',whereArgs:[snapshot['id']]);
        final expected=snapshot['after'] as Map<String,dynamic>;
        if(partner.isEmpty||expected.entries.any((e)=>partner.single[e.key]!=e.value))return false;
      }
      if(change['sample_after']!=null) {
        final sample=await db.query('learning_example',where:'tx_id=?',whereArgs:[change['tx_id']]);
        if(sample.isEmpty || jsonEncode(sample.first)!=change['sample_after']) return false;
      }
    }
    for(final change in changes) {
      final live=(await db.query('tx',where:'id=?',whereArgs:[change['tx_id']])).single;
      await pauseAutoForTx(db,change['tx_id'] as String);
      if(live['auto_pair_before']!=null&&live['auto_applied_key']!=null){
        final snapshot=jsonDecode(live['auto_pair_before'] as String) as Map<String,dynamic>;
        await pauseAutoForTx(db,snapshot['id'] as String);
        await db.update('tx',Map<String,Object?>.from(snapshot['before'] as Map),where:'id=?',whereArgs:[snapshot['id']]);
        await db.update('tx',{'pair_id':null,'auto_pair_before':null},where:'id=?',whereArgs:[change['tx_id']]);
      }
      final before=jsonDecode(change['before_json'] as String) as Map<String,dynamic>;
      await db.update('tx',{...before,'updated_at':DateTime.now().millisecondsSinceEpoch},where:'id=?',whereArgs:[change['tx_id']]);
      await pauseAutoForTx(db,change['tx_id'] as String);
      if(before['status']=='candidate'){
        await db.update('notif_feedback',{'verdict':'undone','at':DateTime.now().microsecondsSinceEpoch},
          where:"tx_id=? AND verdict IN ('yes','fixed')",whereArgs:[change['tx_id']]);
      }
      await db.delete('learning_example',where:'tx_id=?',whereArgs:[change['tx_id']]);
      await db.delete('learning_suggestion',where:'tx_id=?',whereArgs:[change['tx_id']]);
      if(change['sample_before']!=null) {
        await db.insert('learning_example',jsonDecode(change['sample_before'] as String) as Map<String,dynamic>,
          conflictAlgorithm:ConflictAlgorithm.replace);
      }
      if(change['keyword']!=null) {
        final newer=await db.query('classification_history',where:'keyword=? AND undone=0 AND created_at>?',whereArgs:[change['keyword'],change['created_at']]);
        final rule=await db.query('rule',where:'keyword=?',whereArgs:[change['keyword']]);
        if(newer.isEmpty && rule.isNotEmpty && rule.first['category']==change['rule_after']) {
          if(change['rule_before']==null) { await db.delete('rule',where:'keyword=?',whereArgs:[change['keyword']]); }
          else { await db.update('rule',{'category':change['rule_before']},where:'keyword=?',whereArgs:[change['keyword']]); }
        }
      }
      await db.update('classification_history',{'undone':1},where:'id=?',whereArgs:[change['id']]);
    }
    return true;
  });
  Future<void> pairTransfers() async {
    final rows=await _db.query('tx',where:"deleted_at IS NULL AND ${confirmedTxFilter()} AND amount>0 AND pair_id IS NULL AND dir IN ('out','in') AND account IS NOT NULL",orderBy:'occurred_at');
    final used=<String>{};
    for(final out in rows.where((r)=>r['dir']=='out')) {
      if(used.contains(out['id'])) continue;
      final candidates=rows.where((i)=>i['dir']=='in' && i['account']!=out['account'] && i['amount']==out['amount'] && !used.contains(i['id']) && ((i['occurred_at'] as int)-(out['occurred_at'] as int)).abs()<=300000 &&
        (out['destination']==null || out['destination']==i['account']) &&
        (i['destination']==null || i['destination']==out['account']) &&
        ((i['type']=='transfer' && out['type']=='transfer') || i['counterparty']==out['account'] || out['counterparty']==i['account'])).toList();
      if(candidates.length!=1) continue;
      final incoming=candidates.single;
      await _db.transaction((db) async {
        final fresh = await db.query('tx', where: 'id IN (?,?) AND pair_id IS NULL AND deleted_at IS NULL', whereArgs: [out['id'], incoming['id']]);
        if (fresh.length != 2) return;
        for(final (a,b) in [(out,incoming),(incoming,out)]) {
          if(a['auto_applied_key']!=null){
            final history=await db.query('classification_history',where:'tx_id=? AND undone=0',whereArgs:[a['id']],orderBy:'created_at DESC',limit:1);
            if(history.isNotEmpty){final after=jsonDecode(history.single['after_json'] as String) as Map<String,dynamic>;
              if(after['auto_applied_key']==a['auto_applied_key'])await db.update('classification_history',{'after_json':jsonEncode({...after,'type':'transfer','destination':b['account']})},where:'id=?',whereArgs:[history.single['id']]);
            }
            await db.update('tx',{'auto_pair_before':jsonEncode({'id':b['id'],
              'before':{for(final f in ['type','pair_id','destination'])f:b[f]},
              'after':{'type':'transfer','pair_id':a['id'],'destination':a['account']}})},where:'id=?',whereArgs:[a['id']]);
          }
          // 연결로 거래 구조가 바뀌었으므로 이전 구조에서 승인한 예제는 다시 확인한다.
          await db.delete('learning_example',where:'tx_id=?',whereArgs:[a['id']]);
          await db.delete('learning_suggestion',where:'tx_id=?',whereArgs:[a['id']]);
          await db.update('tx',{'type':'transfer','pair_id':b['id'],'destination':b['account']},where:'id=? AND pair_id IS NULL',whereArgs:[a['id']]);
        }
      });
      used.add(out['id'] as String); used.add(incoming['id'] as String);
    }
  }

  Future<void> addGuided({required String kind,required int amount,required String title,required String account,String? destination,required String category,required DateTime at,String? note}) async {
    if(amount<=0 || !['expense','income','transfer'].contains(kind)) throw ArgumentError('거래 입력을 확인하세요');
    if(kind=='transfer' && (destination==null || destination==account)) throw ArgumentError('서로 다른 보내는/받는 통장을 선택하세요');
    final from=await resolveAccount(account), to=await resolveAccount(destination);
    if (kind=='transfer') {
      for (final key in [from,to]) {
        if (key=='현금' || (await _db.query('account',where:'key=?',whereArgs:[key])).isEmpty) throw ArgumentError('내 통장을 먼저 등록하세요');
      }
    }
    if(kind=='transfer' && from==to) throw ArgumentError('동일한 통장의 별칭입니다');
    await _db.transaction((db) async {
      final id=_newId(), other=kind=='transfer'?_newId():null;
      await db.insert('tx',{'id':id,'type':kind,'amount':amount,'merchant':title,'category':category,'occurred_at':at.millisecondsSinceEpoch,'account':from,'destination':to,'counterparty':to,'pair_id':other,'dir':kind=='income'?'in':'out','note':note,'source':'manual','status':'ok','updated_at':DateTime.now().millisecondsSinceEpoch});
      if(other!=null) await db.insert('tx',{'id':other,'type':'transfer','amount':amount,'merchant':title,'category':category,'occurred_at':at.millisecondsSinceEpoch,'account':to,'destination':from,'counterparty':from,'pair_id':id,'dir':'in','note':note,'source':'manual','status':'ok','updated_at':DateTime.now().millisecondsSinceEpoch});
      await _rememberApproval(db,(await db.query('tx',where:'id=?',whereArgs:[id])).single);
    });
  }
}
