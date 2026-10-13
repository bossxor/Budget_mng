// 아이콘 PNG 생성: flutter test tool/make_icon_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

const _blue = ui.Color(0xFF2F6FED);

void _coins(ui.Canvas c) {
  final fill = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  final sep = ui.Paint()
    ..color = _blue
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 22;
  final inner = ui.Paint()
    ..color = const ui.Color(0xFFBFD3FA)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 12;
  // 뒤 -> 앞 순서로 겹쳐 그린다.
  for (final o in const [
    ui.Offset(600, 410),
    ui.Offset(430, 540),
    ui.Offset(610, 640),
  ]) {
    c.drawCircle(o, 175, fill);
    c.drawCircle(o, 175, sep);
    c.drawCircle(o, 125, inner);
  }
}

Future<void> _save(String path, {required bool background}) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  if (background) c.drawRect(const ui.Rect.fromLTWH(0, 0, 1024, 1024), ui.Paint()..color = _blue);
  _coins(c);
  final img = await rec.endRecording().toImage(1024, 1024);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('make icon', (t) async {
    await t.runAsync(() async {
      await _save('assets/icon/icon.png', background: true);
      await _save('assets/icon/foreground.png', background: false);
    });
  });
}
