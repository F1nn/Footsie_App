import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footsie/main.dart' as app;

void main() {
  testWidgets('App builds and shows status', (WidgetTester tester) async {
    await tester.pumpWidget(const app.MyApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('Status:'), findsOneWidget);
    expect(find.text('Scan & Connect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Logs'), findsOneWidget);
  });
}
