// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/pages/home_page.dart';
import 'package:flutter_application_1/pages/settings_page.dart';

void main() {
  testWidgets('HomePage displays monitoring state and counts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: HomePage(
          monitoring: true,
          isSideLying: true,
          remindCount: 3,
          thresholdSeconds: 15,
          onToggleMonitoring: () {},
        ),
      ),
    );

    expect(find.text('枕边哨'), findsOneWidget);
    expect(find.text('今日提醒次数'), findsOneWidget);
    expect(find.text('3 次'), findsOneWidget);
    expect(find.text('监测中'), findsWidgets);
    expect(find.text('≥ 15 秒'), findsOneWidget);
  });

  testWidgets('SettingsPage updates slider label when dragged', (tester) async {
    double threshold = 30;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SettingsPage(
                vibrationEnabled: true,
                thresholdSeconds: threshold.round(),
                dndStart: const TimeOfDay(hour: 23, minute: 0),
                dndEnd: const TimeOfDay(hour: 7, minute: 0),
                onVibrationChanged: (_) {},
                onThresholdChanged: (value) => setState(() => threshold = value),
                onDndStartChanged: (_) {},
                onDndEndChanged: (_) {},
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('30 秒'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(100, 0));
    await tester.pump();
    expect(threshold, greaterThan(30));
    expect(find.text('${threshold.round()} 秒'), findsOneWidget);
  });
}
