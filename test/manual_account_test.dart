import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
void main() {
  sqfliteFfiInit();
  test('직접 등록한 통장은 유지되고 배분의 출발지와 목적지로 선택된다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final repo = await Repo.fromDb(db);
    await repo.addAccount(' 생활비 통장 ', role: 'living');
    await repo.addAccount('여행 통장', role: 'travel');
    final accounts = await repo.accounts();
    expect(accounts, hasLength(2));
    expect(accounts.firstWhere((a) => a.key == '생활비 통장').role, 'living');
    expect(accounts.every((a) => a.balance == null), isTrue);
    await expectLater(repo.addAccount('생활비 통장'), throwsA(isA<DatabaseException>()));
    await expectLater(repo.addAccount(' '), throwsArgumentError);
    await repo.planning.addPlan('생활비 통장', '여행 통장', 50000, 10);
    expect((await repo.planning.plans()).single.fromKey, '생활비 통장');
    expect((await Repo.fromDb(db)).accounts(), completion(hasLength(2)));
  });
}
