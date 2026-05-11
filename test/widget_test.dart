import 'package:flutter_test/flutter_test.dart';

import 'package:absence_scanner_app/main.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const AbsenceScannerApp());

    expect(find.text('Scanner'), findsOneWidget);
    expect(find.text("Scan d'Absences"), findsOneWidget);
  });
}
