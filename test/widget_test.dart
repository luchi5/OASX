import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oasx/main.dart';

void main() {
  testWidgets('OASX shared scrolling supports touch and mouse without starting services', (tester) async {
    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: GlobalBehavior(),
      home: Scaffold(body: ListView.builder(
        controller: scroll,
        itemExtent: 60,
        itemCount: 40,
        itemBuilder: (_, index) => Text('Account $index'),
      )),
    ));
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      scroll.jumpTo(0);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)), kind: kind);
      await gesture.moveBy(const Offset(0, -240));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0), reason: '$kind must scroll the account list');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });
}
