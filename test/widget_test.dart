// Widget test untuk CanSat GCS.
// Test sederhana: pastikan app bisa dibuild tanpa error dan
// menampilkan elemen UI utama (judul, tab, status bar).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

import 'package:ts1/main.dart';

void main() {
  // Window manager butuh binding sebelum test.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mock window manager supaya tidak crash di test environment.
    await windowManager.ensureInitialized();
  });

  testWidgets('GCS app renders main widgets', (WidgetTester tester) async {
    await tester.pumpWidget(const GcsApp());
    await tester.pump(); // satu frame

    // Verifikasi judul header muncul
    expect(find.text('CanSat Ground Control Station'), findsOneWidget);

    // Verifikasi tab utama muncul
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Live Charts'), findsOneWidget);
    expect(find.text('Attitude & GPS'), findsOneWidget);
  });

  testWidgets('Dashboard shows metric cards', (WidgetTester tester) async {
    await tester.pumpWidget(const GcsApp());
    await tester.pump();

    // Verifikasi section title
    expect(find.text('FLIGHT DATA'), findsOneWidget);
    expect(find.text('ATTITUDE'), findsOneWidget);
    expect(find.text('GPS & MISSION'), findsOneWidget);

    // Verifikasi beberapa metric card title
    expect(find.text('ALTITUDE'), findsOneWidget);
    expect(find.text('TEMPERATURE'), findsOneWidget);
    expect(find.text('BATTERY VOLTAGE'), findsOneWidget);
  });
}
