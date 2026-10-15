import 'package:flutter/material.dart';
import '../app_state.dart';
import '../data/repo.dart';
import 'theme.dart';

Future<bool?> showGuidedEntry(BuildContext context, AppState s,
    {String? initialType, int? initialAmount, String? initialTitle}) =>
    showModalBottomSheet<bool>(context: context, useSafeArea: true,
      isScrollControlled: true, showDragHandle: true,
      builder: (_) => _GuidedEntry(s, initialType, initialAmount, initialTitle));

class _GuidedEntry extends StatefulWidget {
  const _GuidedEntry(this.s,this.type,this.amount,this.title);
  final AppState s;
  final String? type,title;
  final int? amount;
  @override State<_GuidedEntry> createState()=>_GuidedEntryState();
}
class _GuidedEntryState extends State<_GuidedEntry> {
  late final TextEditingController amount,title;
  final note=TextEditingController();
  late String kind;
  late int step;
  String? account,destination,error;
  String category='식비';
  DateTime at=DateTime.now();
  bool saving=false;
  @override void initState(){super.initState();
    amount=TextEditingController(text:widget.amount?.toString()??'');
    title=TextEditingController(text:widget.title??'');
    kind=widget.type??'expense';step=widget.amount==null?0:1;
    category=kind=='income'?'기타수입':'식비';
    account=widget.s.accounts.firstOrNull?.key??'현금';
  }
  @override void dispose(){amount.dispose();title.dispose();note.dispose();super.dispose();}
  List<String> get categories=>kind=='saving'?['적금','여행저축','비상금']:kind=='transfer'?transferPurposes:kind=='income'?['월급','용돈','기타수입']:allCategories;
  Widget accountField(String label,String? value,ValueChanged<String?> change,{bool receiving=false})=>DropdownButtonFormField<String>(
    initialValue:value, isExpanded:true, decoration:InputDecoration(labelText:label,filled:false,border:InputBorder.none,enabledBorder:InputBorder.none,focusedBorder:InputBorder.none),
    items:[if(!receiving) const DropdownMenuItem(value:'현금',child:Text('현금')),
      for(final a in widget.s.accounts.where((a)=>(!receiving || a.key!=account) && a.key!='현금'))
        DropdownMenuItem(value:a.key,child:Text(a.selectionLabel,overflow:TextOverflow.ellipsis))],
    onChanged:saving?null:change);
  @override Widget build(BuildContext context){
    final cs=Theme.of(context).colorScheme;
    final moving=kind=='saving'||kind=='transfer';
    return SingleChildScrollView(padding:EdgeInsets.fromLTRB(22,0,22,22+MediaQuery.of(context).viewInsets.bottom+MediaQuery.of(context).padding.bottom),
      child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(step==0?'1 / 2 · 돈의 성격':'2 / 2 · 금액과 통장',style:TextStyle(color:cs.onSurfaceVariant,fontSize:12)),
        const SizedBox(height:10),
        Text(step==0?'어떤 돈이 움직였나요?':moving?'어디로 옮겼나요?':'얼마가 움직였나요?',style:const TextStyle(fontSize:24,fontWeight:FontWeight.w700)),
        const SizedBox(height:22),
        if(step==0)...[
          LayoutBuilder(builder:(context,constraints){
            final twoColumns=constraints.maxWidth>=300 && MediaQuery.textScalerOf(context).scale(14)<=18;
            final width=twoColumns?(constraints.maxWidth-10)/2:constraints.maxWidth;
            return Wrap(spacing:10,runSpacing:10,children:[
              for(final row in [('expense','물건·서비스에 쓴 돈','식사, 쇼핑, 교통 등',Icons.shopping_bag_outlined),('income','새로 들어온 돈','월급, 용돈 등',Icons.south_west_rounded),('saving','저축으로 옮긴 돈','적금, 여행자금 등',Icons.savings_outlined),('transfer','통장 사이에 옮긴 돈','생활비 이동, 카드대금 등',Icons.swap_horiz_rounded)])
                SizedBox(width:width,child:Material(color:kind==row.$1?cs.primaryContainer:cs.surface,borderRadius:BorderRadius.circular(18),
                  child:InkWell(borderRadius:BorderRadius.circular(18),onTap:()=>setState((){kind=row.$1;category=categories.first;destination=null;}),
                    child:ConstrainedBox(constraints:BoxConstraints(minHeight:twoColumns?164:0),child:Padding(padding:const EdgeInsets.all(15),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Row(children:[RoundIcon(row.$4,Dsn.blue,size:34),const Spacer(),if(kind==row.$1)Icon(Icons.check_circle,color:cs.primary,size:20)]),
                      const SizedBox(height:12),Text(row.$2,style:const TextStyle(fontWeight:FontWeight.w600,fontSize:14)),
                      const SizedBox(height:7),Text(row.$3,style:TextStyle(color:cs.onSurfaceVariant,fontSize:12)),
                    ])))))),
            ]);
          }),
          const SizedBox(height:18),          SizedBox(width:double.infinity,child:FilledButton(onPressed:()=>setState(()=>step=1),child:const Text('다음'))),
        ]else...[
          TextField(controller:amount,keyboardType:TextInputType.number,
            style:const TextStyle(fontSize:34,fontWeight:FontWeight.w700),decoration:const InputDecoration(labelText:'금액',suffixText:'원',suffixStyle:TextStyle(fontSize:20,fontWeight:FontWeight.w600),filled:false,border:UnderlineInputBorder(),enabledBorder:UnderlineInputBorder(borderSide:BorderSide(color:Color(0xFFDCE3EF))))),
          const SizedBox(height:16),
          Container(decoration:BoxDecoration(color:cs.surface,borderRadius:BorderRadius.circular(18)),
            padding:const EdgeInsets.symmetric(horizontal:16,vertical:4),
            child:Column(children:[
              TextField(controller:title,decoration:InputDecoration(labelText:'내용',hintText:moving?'예: 이번 달 적금':'예: 점심 식사',filled:false,border:InputBorder.none,enabledBorder:InputBorder.none,focusedBorder:InputBorder.none)),
              Divider(color:cs.outlineVariant.withValues(alpha:0.4),height:1),
              accountField(kind=='income'?'받는 통장':moving?'보내는 통장':'사용한 통장',account,(v)=>setState((){account=v;if(destination==v)destination=null;})),
              if(moving)...[Divider(color:cs.outlineVariant.withValues(alpha:0.4),height:1),accountField('받는 통장',destination,(v)=>setState(()=>destination=v),receiving:true)],
              Divider(color:cs.outlineVariant.withValues(alpha:0.4),height:1),
              DropdownButtonFormField<String>(initialValue:category,isExpanded:true,
                decoration:InputDecoration(labelText:moving?'이체 목적':'분류',filled:false,border:InputBorder.none,enabledBorder:InputBorder.none,focusedBorder:InputBorder.none),
                items:[for(final c in categories)DropdownMenuItem(value:c,child:Text(c))],onChanged:saving?null:(v)=>setState(()=>category=v!)),
            ])),          if(moving)Padding(padding:const EdgeInsets.only(top:12),child:Text('내 통장 사이 이동은 소비 지출에서 제외합니다. 저축 목적 또는 저축 통장으로 보낸 돈은 저축 실적에도 반영해요.',style:TextStyle(color:cs.onSurfaceVariant,fontSize:12))),
          ExpansionTile(tilePadding:EdgeInsets.zero,title:const Text('날짜·메모 더하기',style:TextStyle(fontSize:13)),children:[
            ListTile(contentPadding:EdgeInsets.zero,title:Text('${at.year}.${at.month}.${at.day}'),trailing:const Icon(Icons.calendar_month_outlined),onTap:()async{final date=await showDatePicker(context:context,initialDate:at,firstDate:DateTime(2000),lastDate:DateTime.now());if(date!=null)setState(()=>at=DateTime(date.year,date.month,date.day,at.hour,at.minute));}),
            TextField(controller:note,decoration:const InputDecoration(labelText:'메모'))]),
          if(error!=null)Text(error!,style:TextStyle(color:cs.error)),
          const SizedBox(height:16),
          SizedBox(width:double.infinity,child:FilledButton(onPressed:saving?null:()async{
            final value=int.tryParse(amount.text.replaceAll(',','').trim());
            if(value==null||value<=0){setState(()=>error='금액을 입력하세요');return;}
            if(moving&&(account=='현금'||destination==null||account==destination)){setState(()=>error='서로 다른 보내는 통장과 받는 통장을 선택하세요. 통장 탭에서 먼저 추가할 수 있어요.');return;}
            setState((){saving=true;error=null;});
            try{await widget.s.repo.addGuided(kind:moving?'transfer':kind,amount:value,title:title.text.trim().isEmpty?category:title.text.trim(),account:account!,destination:destination,category:category,at:at,note:note.text.trim());await widget.s.refresh();if(context.mounted)Navigator.pop(context,true);}
            catch(_){if(mounted)setState((){saving=false;error='저장하지 못했어요. 다시 확인해 주세요.';});}
          },child:Text(saving?'저장 중…':'저장'))),
          TextButton(onPressed:saving?null:()=>setState(()=>step=0),child:const Text('돈의 성격 다시 선택')),
        ],
      ]));
  }
}
