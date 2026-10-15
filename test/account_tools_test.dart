import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now=DateTime.now().subtract(const Duration(days: 1));
  setUp(() async {db=await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,options:OpenDatabaseOptions(singleInstance:false));repo=await Repo.fromDb(db);});
  tearDown(() async => db.close());
  test('학습 규칙과 분류를 되돌리고 이체 목적은 소비 규칙을 오염시키지 않는다',()async{
    await repo.addManual(type:'expense',amount:10000,title:'동네가게',at:now);
    final tx=(await repo.monthTx(now)).single;
    await repo.setCategory(tx,'카페');
    expect((await repo.learnedRules())['동네가게'],'카페');
    await repo.setCategory((await repo.monthTx(now)).single,'식비');
    expect(await repo.undoClassification(tx.id),true);
    expect((await repo.learnedRules())['동네가게'],'카페');
    expect(await repo.undoClassification(tx.id),true);
    expect((await repo.learnedRules()).containsKey('동네가게'),false);
    await repo.setType(tx.id,'transfer');
    await repo.setCategory((await repo.monthTx(now)).single,'적금');
    expect((await repo.summary(now)).expense,0);
    expect((await repo.learnedRules()).containsKey('동네가게'),false);
  });
  test('안내형 이체는 지출 0, 저축 1회, 한 행 표시, 쌍의 목적 변경/되돌리기',()async{
    await repo.addAccount('생활비',role:'living');await repo.addAccount('적금',role:'saving');
    await repo.addGuided(kind:'transfer',amount:300000,title:'저축',account:'생활비',destination:'적금',category:'적금',at:now);
    var rows=await repo.monthTx(now);
    expect(rows,hasLength(2));expect(collapseTransfers(rows),hasLength(1));
    expect((await repo.summary(now)).expense,0);
    expect((await repo.planning.savings(now)).saved,300000);
    expect(rows.every((r)=>r.route=='생활비 → 적금'),true);
    final id=collapseTransfers(rows).single.id;
    await repo.setCategory(collapseTransfers(rows).single,'여행저축');
    expect((await repo.monthTx(now)).every((r)=>r.category=='여행저축'),true);
    expect(await repo.undoClassification(id),true);
    expect((await repo.monthTx(now)).every((r)=>r.category=='적금'),true);
    await repo.updateTx(id,amount:400000);
    expect((await repo.monthTx(now)).every((r)=>r.amount==400000),true);
    await repo.delete(id);expect(await repo.monthTx(now),isEmpty);
  });
  test('별칭 연결은 거래와 배분을 보존하며 잔액은 기준일 이후 알림 우선',()async{
    await repo.addAccount('알림 계좌');await repo.addAccount('생활비');await repo.addAccount('적금',role:'saving');
    await db.insert('tx',{'id':'old','type':'income','amount':1000,'account':'알림 계좌','balance':10000,'occurred_at':now.subtract(const Duration(days:1)).millisecondsSinceEpoch});
    await repo.planning.addPlan('알림 계좌','적금',1000,15);
    await repo.linkAccount('알림 계좌','생활비');
    expect(await repo.resolveAccount('알림 계좌'),'생활비');
    expect(await repo.accounts(),hasLength(2));
    expect((await repo.monthTx(now)).single.account,'생활비');
    expect((await repo.planning.plans()).single.fromKey,'생활비');
    await repo.correctBalance('생활비',50000,now);
    expect((await repo.accounts()).firstWhere((a)=>a.key=='생활비').balance,50000);
    await db.insert('tx',{'id':'new','type':'income','amount':1000,'account':'생활비','balance':51000,'occurred_at':now.add(const Duration(minutes:1)).millisecondsSinceEpoch});
    expect((await repo.accounts()).firstWhere((a)=>a.key=='생활비').balance,51000);
    await expectLater(repo.linkAccount('생활비','알림 계좌'),throwsArgumentError);
    final backup=await exportData(db);
    final other=await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,options:OpenDatabaseOptions(singleInstance:false));
    final restored=await Repo.fromDb(other);await importData(other,backup);
    expect(await restored.resolveAccount('알림 계좌'),'생활비');await other.close();
    await Repo.fromDb(db);expect(await repo.accounts(),hasLength(2));
  });
  test('동액이어도 상대/방향 근거 없는 거래는 이체로 묶지 않는다',()async{
    await db.insert('tx',{'id':'out','type':'expense','amount':1000,'account':'A','counterparty':'가게','dir':'out','occurred_at':now.millisecondsSinceEpoch});
    await db.insert('tx',{'id':'in','type':'income','amount':1000,'account':'B','counterparty':'회사','dir':'in','occurred_at':now.millisecondsSinceEpoch});
    await repo.pairTransfers();expect((await repo.summary(now)).expense,1000);
    expect((await repo.monthTx(now)).every((r)=>r.pairId==null),true);
  });
  test('동시 컬럼 추가의 중복만 허용하고 다른 SQL 오류는 숨기지 않는다',()async{
    await db.execute('CREATE TABLE migration_probe(id TEXT)');
    await Future.wait([addColumnSafely(db,'migration_probe','value INTEGER'),addColumnSafely(db,'migration_probe','value INTEGER')]);
    final columns=await db.rawQuery('PRAGMA table_info(migration_probe)');
    expect(columns.where((c)=>c['name']=='value'),hasLength(1));
    await expectLater(addColumnSafely(db,'missing_table','value INTEGER'),throwsA(isA<DatabaseException>()));
  });
}
