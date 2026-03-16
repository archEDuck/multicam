import 'package:flutter_test/flutter_test.dart';

import 'package:multicam/main.dart';

void main() {
  testWidgets('Shows multicam screen shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Multicam Capture (S23)'), findsOneWidget);
    expect(find.text('Kaydi Baslat'), findsOneWidget);
  });
}
