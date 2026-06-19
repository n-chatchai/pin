import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pin/widgets/html_view.dart';

Future<void> _pump(WidgetTester tester, String html) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: HtmlView(html))),
  ));
  await tester.pump();
}

void main() {
  testWidgets('renders styled table', (tester) async {
    await _pump(tester, '''
      <h3>ตาราง</h3>
      <table><tr><th>ชื่อ</th><th>ราคา</th></tr>
      <tr><td>กาแฟ</td><td style="color:#2E9E63">฿60</td></tr></table>
      <p>สรุป <b>ดี</b></p>''');
    expect(tester.takeException(), isNull);
    expect(find.byType(HtmlView), findsOneWidget);
  });

  testWidgets('renders remote img without throwing', (tester) async {
    await _pump(tester,
        '<div><img src="https://example.com/x.png" alt="pic"><p>คำอธิบาย</p></div>');
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders link and styled divs', (tester) async {
    await _pump(tester,
        '<div style="padding:8px"><a href="https://x.com">ลิงก์</a> '
        '<span style="color:red">เด่น</span></div>');
    expect(tester.takeException(), isNull);
  });

  testWidgets('handles empty and plain text', (tester) async {
    await _pump(tester, '');
    expect(tester.takeException(), isNull);
    await _pump(tester, 'สวัสดีครับ');
    expect(tester.takeException(), isNull);
  });
}
