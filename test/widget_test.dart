import 'package:flutter_test/flutter_test.dart';

import 'package:multicam/main.dart';

void main() {
  testWidgets('Shows multicam screen shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Stereo Pipeline'), findsOneWidget);
    expect(find.text('Kaydı Başlat'), findsNothing);
    expect(find.text('Faz 2’ye Geç (Kalibrasyon)'), findsOneWidget);
  });
}
