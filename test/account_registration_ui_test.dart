import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/ui/account_registration.dart';
import 'package:jumeoni/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RegistrationState extends AppState {
  _RegistrationState(super.repo);
  Completer<void>? completed;
  @override Future<void> refresh()async{
    await super.refresh();
    if(completed!=null && !completed!.isCompleted){completed!.complete();}
  }
}

void main(){
  sqfliteFfiInit();
  late Database db;late _RegistrationState state;
  setUp(()async{db=await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
    options:OpenDatabaseOptions(singleInstance:false));state=_RegistrationState(await Repo.fromDb(db));});
  tearDown(()async{state.dispose();await db.close();});

  Future<void> open(WidgetTester tester,{AccountRow? account})async{
    tester.view.physicalSize=const Size(390,900);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme:Dsn.theme(Brightness.light,(t)=>t),
      home:Scaffold(body:Builder(builder:(context)=>TextButton(
        onPressed:()=>showAccountRegistration(context,state,account:account),child:const Text('등록 열기'))))));
    await tester.tap(find.text('등록 열기'));await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester,int index,String bank,String number,String label)async{
    final tile=find.byType(ExpansionTile).at(index);
    final bankField=find.descendant(of:tile,matching:find.byType(DropdownButtonFormField<String>)).first;
    await tester.ensureVisible(bankField);await tester.tap(bankField);await tester.pumpAndSettle();
    await tester.tap(find.text(bank).last);await tester.pumpAndSettle();
    final fields=find.descendant(of:tile,matching:find.byType(TextField));
    await tester.ensureVisible(fields.first);await tester.enterText(fields.first,number);
    await tester.ensureVisible(fields.at(1));await tester.enterText(fields.at(1),label);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester,String title)async{
    state.completed=Completer<void>();await tester.tap(find.text(title));
    for(var i=0;i<100 && !state.completed!.isCompleted;i++){
      await tester.pump();await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:20)));
    }
    await tester.pumpAndSettle();expect(state.completed!.isCompleted,true);
  }

  testWidgets('여러 통장을 확인 화면에서 가려 보여주고 한 번에 저장한다',(tester)async{
    await open(tester);await fill(tester,0,'NH농협은행','012-345-678901','생활비');
    await tester.scrollUntilVisible(find.text('통장 더 추가'),200,scrollable:find.byType(Scrollable).first);
    await tester.tap(find.text('통장 더 추가'));await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('통장 2'),150,scrollable:find.byType(Scrollable).first);
    await fill(tester,1,'카카오뱅크','3333-01-1234567','내 적금');
    await tester.tap(find.text('2개 등록 내용 확인'));await tester.pumpAndSettle();
    expect(find.text('이 내용으로 등록할까요?'),findsOneWidget);
    expect(find.textContaining('•••• 8901'),findsOneWidget);
    expect(find.textContaining('012-345-678901'),findsNothing);
    expect(await tester.runAsync(()=>state.repo.accounts()),isEmpty);
    await save(tester,'2개 통장 등록');
    expect(state.accounts,hasLength(2));expect(find.text('등록 열기'),findsOneWidget);
    expect(state.accounts.firstWhere((a)=>a.bankCode=='nh').accountNumber,'012345678901');
    expect(tester.takeException(),isNull);
  });

  testWidgets('키보드와 하단 바 위에 버튼을 두고 입력 오류는 저장하지 않는다',(tester)async{
    await open(tester);
    tester.view.viewPadding=const FakeViewPadding(bottom:34);
    tester.view.padding=FakeViewPadding.zero;
    tester.view.viewInsets=const FakeViewPadding(bottom:300);
    await tester.pumpAndSettle();
    final button=find.widgetWithText(FilledButton,'1개 등록 내용 확인');
    expect(tester.getBottomRight(button).dy,lessThanOrEqualTo(600));
    await tester.tap(button);await tester.pumpAndSettle();
    expect(find.text('은행을 선택해 주세요.'),findsWidgets);
    expect(await tester.runAsync(()=>state.repo.accounts()),isEmpty);
    expect(tester.takeException(),isNull);
  });

  testWidgets('기존 통장의 정보만 추가하며 제거한 입력 행은 저장하지 않는다',(tester)async{
    await tester.runAsync(()async{await state.repo.addAccount('생활비');state.accounts=await state.repo.accounts();});
    await open(tester,account:state.accounts.single);
    await fill(tester,0,'NH농협은행','012345678901','월급 통장');
    await tester.scrollUntilVisible(find.text('통장 더 추가'),200,scrollable:find.byType(Scrollable).first);
    await tester.tap(find.text('통장 더 추가'));await tester.pumpAndSettle();
    final removeSecond=find.descendant(of:find.byType(ExpansionTile).at(1),matching:find.text('목록에서 빼기'));
    await tester.scrollUntilVisible(removeSecond,200,scrollable:find.byType(Scrollable).first);
    await tester.tap(removeSecond);await tester.pumpAndSettle();
    await tester.tap(find.text('1개 등록 내용 확인'));await tester.pumpAndSettle();
    expect(find.textContaining('기존 통장 정보 추가'),findsOneWidget);
    await save(tester,'1개 통장 등록');
    expect(state.accounts,hasLength(1));expect(state.accounts.single.key,'생활비');
    expect(state.accounts.single.label,'월급 통장');expect(tester.takeException(),isNull);
  });
}
