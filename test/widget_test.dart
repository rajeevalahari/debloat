// Basic smoke tests for the Debloat UI.

import 'package:flutter_test/flutter_test.dart';

import 'package:debloat/main.dart';

void main() {
  testWidgets('starts in the disconnected state', (WidgetTester tester) async {
    await tester.pumpWidget(const DebloatApp());

    // App bar title.
    expect(find.text('Debloat'), findsOneWidget);
    // Status banner shows Disconnected on launch.
    expect(find.text('Disconnected'), findsOneWidget);
    // Primary action invites the user to connect.
    expect(find.text('Pair & Connect'), findsOneWidget);
    // The three connection inputs are present.
    expect(find.text('Pairing port'), findsOneWidget);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.text('Connection port (optional)'), findsOneWidget);
    // Floating-window entry point is offered while disconnected.
    expect(find.text('Float over Settings to pair'), findsOneWidget);
  });

  testWidgets('shows guidance when not connected', (WidgetTester tester) async {
    await tester.pumpWidget(const DebloatApp());

    expect(find.text('Not connected'), findsOneWidget);
  });
}
