import 'package:flutter/material.dart';
import '../app_state.dart';
import '../core/bank_accounts.dart';
import '../data/repo.dart';
import 'theme.dart';

Future<bool?> showAccountRegistration(BuildContext context,AppState s,{AccountRow? account}) =>
  Navigator.of(context).push<bool>(MaterialPageRoute(
    builder:(_)=>AccountRegistrationScreen(s,account:account)));

class _AccountInput {
  _AccountInput([AccountRow? account]):bank=account?.bankCode,
    role=account?.role??'unset',existingKey=account?.key,
    number=TextEditingController(text:account?.accountNumber??''),
    label=TextEditingController(text:account?.label??''),hidden=account?.accountNumber!=null;
  final key=UniqueKey();
  final anchor=GlobalKey();
  final TextEditingController number,label;
  String? bank,existingKey,error;
  String role;
  bool hidden;
  void dispose(){number.dispose();label.dispose();}
}

class AccountRegistrationScreen extends StatefulWidget {
  const AccountRegistrationScreen(this.s,{this.account,super.key});
  final AppState s;
  final AccountRow? account;
  @override State<AccountRegistrationScreen> createState()=>_AccountRegistrationScreenState();
}

class _AccountRegistrationScreenState extends State<AccountRegistrationScreen> {
  final scroll=ScrollController();
  late final List<_AccountInput> entries=[_AccountInput(widget.account)];
  List<BankAccountDraft> checked=[];
  bool reviewing=false,busy=false;
  String? error;
  List<AccountRow> get existing => widget.s.accounts.where((a)=>
    !RegExp(r'^[가-힣A-Za-z]+\d{4}$').hasMatch(a.key)).toList();

  @override void dispose(){for(final entry in entries){entry.dispose();}scroll.dispose();super.dispose();}

  void check(){
    FocusScope.of(context).unfocus();
    final drafts=<BankAccountDraft>[];
    final identities=<String>{},targets=<String>{};
    _AccountInput? firstError;
    for(final entry in entries){
      entry.error=null;
      try {
        if(entry.bank==null)throw ArgumentError('은행을 선택해 주세요.');
        final number=normalizeAccountNumber(entry.number.text);
        if(entry.label.text.trim().length>40){throw ArgumentError('별칭은 40자 이내로 입력해 주세요.');}
        if(!identities.add('${entry.bank}:$number')){throw ArgumentError('목록에 같은 계좌가 두 번 있어요.');}
        if(entry.existingKey!=null && !targets.add(entry.existingKey!)){throw ArgumentError('같은 기존 통장을 두 번 선택했어요.');}
        if(existing.any((a)=>a.bankCode==entry.bank && a.accountNumber==number && a.key!=entry.existingKey)){
          throw ArgumentError('이미 등록된 계좌예요. 아래에서 기존 통장을 선택해 주세요.');
        }
        drafts.add(BankAccountDraft(bank:entry.bank!,number:number,label:entry.label.text,
          role:entry.role,existingKey:entry.existingKey));
      } on ArgumentError catch(e){entry.error=e.message.toString();firstError??=entry;}
    }
    setState((){error=null;if(firstError==null){checked=drafts;reviewing=true;}});
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(!mounted)return;
      if(firstError?.anchor.currentContext!=null){Scrollable.ensureVisible(firstError!.anchor.currentContext!,duration:const Duration(milliseconds:220));}
      else if(scroll.hasClients){scroll.jumpTo(0);}
    });
  }

  Future<void> save()async{
    if(busy)return;
    setState((){busy=true;error=null;});
    try {await widget.s.repo.registerBankAccounts(checked);}
    catch(e){if(mounted){setState((){busy=false;error=e is ArgumentError?e.message.toString():'저장하지 못했어요. 다시 확인해 주세요.';});}return;}
    // 저장이 끝난 뒤 화면 갱신 실패를 재등록 실패로 표시하지 않는다.
    var refreshed=true;
    try{await widget.s.refresh();}catch(_){refreshed=false;}
    if(!mounted)return;
    final messenger=ScaffoldMessenger.of(context);
    Navigator.pop(context,true);
    messenger.showSnackBar(SnackBar(content:Text(refreshed?
      '${checked.length}개 통장을 등록했어요.':'통장을 등록했어요. 화면을 다시 열면 최신 내역을 확인할 수 있어요.')));
  }

  void add(){
    setState(()=>entries.add(_AccountInput()));
    WidgetsBinding.instance.addPostFrameCallback((_){
      if(mounted && scroll.hasClients){scroll.animateTo(scroll.position.maxScrollExtent,
        duration:const Duration(milliseconds:220),curve:Curves.easeOut);}
    });
  }

  Widget entryCard(_AccountInput entry,int index){
    final cs=Theme.of(context).colorScheme;
    final chosen=existing.where((a)=>a.key==entry.existingKey).firstOrNull;
    return Card(key:entry.anchor,child:ExpansionTile(key:entry.key,initiallyExpanded:true,
      maintainState:true,shape:const Border(),collapsedShape:const Border(),
      title:Text(entry.label.text.trim().isEmpty?'통장 ${index+1}':entry.label.text.trim(),
        style:const TextStyle(fontWeight:FontWeight.w700)),
      subtitle:entry.error!=null?Text(entry.error!,style:TextStyle(color:cs.error,fontSize:12)):
        entry.bank==null?const Text('은행과 계좌번호를 입력하세요',style:TextStyle(fontSize:12)):
        Text('${bankNames[entry.bank]} · ${maskedAccountNumber(entry.number.text.replaceAll(RegExp(r'\D'),''))}',style:const TextStyle(fontSize:12)),
      children:[Padding(padding:const EdgeInsets.fromLTRB(16,0,16,16),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        DropdownButtonFormField<String>(key:ValueKey('bank-${entry.existingKey}'),
          initialValue:entry.bank,isExpanded:true,decoration:const InputDecoration(labelText:'은행'),
          items:[for(final bank in bankNames.entries)DropdownMenuItem(value:bank.key,child:Text(bank.value))],
          onChanged:busy?null:(value)=>setState(()=>entry.bank=value)),
        const SizedBox(height:12),
        TextField(controller:entry.number,keyboardType:TextInputType.number,enabled:!busy,
          obscureText:entry.hidden,enableSuggestions:false,autocorrect:false,
          onChanged:(_)=>setState(()=>entry.error=null),
          decoration:InputDecoration(labelText:'계좌번호',hintText:'숫자 또는 하이픈 포함',
            suffixIcon:IconButton(onPressed:()=>setState(()=>entry.hidden=!entry.hidden),
              tooltip:entry.hidden?'계좌번호 보기':'계좌번호 가리기',
              icon:Icon(entry.hidden?Icons.visibility_outlined:Icons.visibility_off_outlined)))),
        const SizedBox(height:12),
        TextField(controller:entry.label,enabled:!busy,maxLength:40,
          onChanged:(_)=>setState((){}),decoration:const InputDecoration(labelText:'별칭 (선택)',hintText:'예: 생활비, 내 적금',counterText:'')),
        const SizedBox(height:12),
        DropdownButtonFormField<String>(key:ValueKey('role-${entry.existingKey}'),
          initialValue:entry.role,isExpanded:true,decoration:const InputDecoration(labelText:'통장 용도'),
          items:[for(final role in roles.entries)DropdownMenuItem(value:role.key,child:Text(role.value))],
          onChanged:busy?null:(value)=>setState(()=>entry.role=value!)),
        if(existing.isNotEmpty)...[
          const SizedBox(height:14),
          DropdownButtonFormField<String>(initialValue:entry.existingKey??'',isExpanded:true,
            decoration:const InputDecoration(labelText:'기존 통장에 정보 추가 (선택)'),
            items:[const DropdownMenuItem(value:'',child:Text('새 통장으로 등록')),
              for(final account in existing)DropdownMenuItem(value:account.key,child:Text(
                '${account.label}${account.maskedIdentity.isEmpty?'':' · ${account.maskedIdentity}'}',overflow:TextOverflow.ellipsis))],
            onChanged:busy?null:(value)=>setState((){
              entry.existingKey=value==''?null:value;
              final account=existing.where((a)=>a.key==entry.existingKey).firstOrNull;
              if(account!=null){entry.label.text=account.label;entry.role=account.role;
                if(account.bankCode!=null){entry.bank=account.bankCode;entry.number.text=account.accountNumber??'';entry.hidden=true;}}
            })),
          if(chosen!=null)Padding(padding:const EdgeInsets.only(top:8),child:Text('기존 거래·잔액·계획은 그대로 유지해요.',style:TextStyle(color:cs.onSurfaceVariant,fontSize:12))),
        ],
        if(entry.error!=null)Padding(padding:const EdgeInsets.only(top:12),child:Text(entry.error!,style:TextStyle(color:cs.error))),
        if(entries.length>1)Align(alignment:Alignment.centerRight,child:TextButton.icon(
          onPressed:busy?null:(){setState(()=>entries.remove(entry));
            WidgetsBinding.instance.addPostFrameCallback((_)=>entry.dispose());},
          icon:const Icon(Icons.close_rounded,size:18),label:const Text('목록에서 빼기'))),
      ]))]));
  }

  @override Widget build(BuildContext context){
    final cs=Theme.of(context).colorScheme;
    return PopScope(canPop:!busy,child:Scaffold(
      appBar:AppBar(title:const Text('내 통장 모아 등록')),
      body:Column(children:[Expanded(child:ListView(controller:scroll,
        padding:const EdgeInsets.fromLTRB(20,8,20,16),children:[
          Text(reviewing?'이 내용으로 등록할까요?':'내 통장을 한 번에 모아요',style:const TextStyle(fontSize:24,fontWeight:FontWeight.w700)),
          const SizedBox(height:8),Text(reviewing?'계좌번호는 끝 네 자리만 표시했어요.':'은행·계좌번호·별칭과 용도를 적어 주세요.',style:TextStyle(color:cs.onSurfaceVariant)),
          const SizedBox(height:20),
          if(!reviewing)...[
            for(var i=0;i<entries.length;i++)entryCard(entries[i],i),
            OutlinedButton.icon(onPressed:busy?null:add,icon:const Icon(Icons.add_rounded),label:const Text('통장 더 추가')),
          ]else...[
            for(final draft in checked)Card(child:Padding(padding:const EdgeInsets.all(16),
              child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                RoundIcon(Icons.account_balance_outlined,Dsn.role(draft.role),size:38),const SizedBox(width:12),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(draft.label.trim().isEmpty?'${bankNames[draft.bank]} 통장':draft.label.trim(),style:const TextStyle(fontWeight:FontWeight.w700)),
                  const SizedBox(height:4),Text('${bankNames[draft.bank]} · ${maskedAccountNumber(draft.number)}',style:TextStyle(color:cs.onSurfaceVariant,fontSize:13)),
                  const SizedBox(height:4),Text('${roles[draft.role]} · ${draft.existingKey==null?'새 통장':'기존 통장 정보 추가'}',style:TextStyle(color:cs.onSurfaceVariant,fontSize:12)),
                ])),
              ]))),
            const SizedBox(height:10),Text('은행과 전체 계좌번호가 같은 알림을 연결해요. 번호가 가려진 알림은 통장 상세에서 확인 후 연결할 수 있어요.',style:TextStyle(color:cs.onSurfaceVariant,fontSize:13)),
          ],
          if(error!=null)Padding(padding:const EdgeInsets.only(top:14),child:Text(error!,style:TextStyle(color:cs.error))),
        ])),
        SafeArea(top:false,child:Padding(padding:const EdgeInsets.fromLTRB(20,10,20,14),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text('기기 안에 저장 · 목록에서는 계좌번호 가림',textAlign:TextAlign.center,style:TextStyle(fontSize:11,color:cs.onSurfaceVariant)),
          const SizedBox(height:10),
          FilledButton(onPressed:busy?null:reviewing?save:check,
            child:Text(busy?'등록 중…':reviewing?'${checked.length}개 통장 등록':'${entries.length}개 등록 내용 확인')),
          if(reviewing)TextButton(onPressed:busy?null:()=>setState(()=>reviewing=false),child:const Text('입력 내용 수정')),
        ]))),
      ])));
  }
}
