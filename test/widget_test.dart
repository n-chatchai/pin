import 'package:flutter_test/flutter_test.dart';

import 'package:pin/main.dart';

void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const PinApp());
    expect(find.byType(PinApp), findsOneWidget);
  });
}
