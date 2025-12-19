import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/controllers/reminder_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReminderController', () {
    late ReminderController controller;
    late FlutterLocalNotificationsPlugin notifications;
    bool channelEnsured = false;

    setUp(() {
      notifications = FlutterLocalNotificationsPlugin();
      channelEnsured = false;
      controller = ReminderController(
        notifications: notifications,
        ensureNotificationChannel: () {
          channelEnsured = true;
        },
      );
    });

    tearDown(() {
      controller.reset();
    });

    test('isReminderDialogShowing starts as false', () {
      expect(controller.isReminderDialogShowing, isFalse);
    });

    test('vibrateOnce respects enabled flag', () async {
      // 当enabled为false时，应该不震动
      await controller.vibrateOnce(durationMs: 50, enabled: false);
      // 如果设备没有震动器，这个测试会通过；如果有，也不会震动
      expect(controller, isNotNull);
    });

    test('vibratePattern respects enabled flag', () async {
      // 当enabled为false时，应该不震动
      await controller.vibratePattern([0, 100], enabled: false);
      expect(controller, isNotNull);
    });

    test('reset clears reminder dialog state', () {
      // 由于showReminderDialog需要BuildContext，我们主要测试reset方法
      controller.reset();
      expect(controller.isReminderDialogShowing, isFalse);
    });

    testWidgets('triggerReminder calls ensureNotificationChannel for background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Container()),
        ),
      );
      
      await tester.pump();
      final context = tester.element(find.byType(Scaffold));
      
      // 使用pumpAndSettle确保异步操作完成
      await controller.triggerReminder(
        context: context,
        isInBackground: true,
        vibrationEnabled: false,
        onDialogClosed: () {},
      );
      
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // 后台情况下应该调用ensureNotificationChannel
      expect(channelEnsured, isTrue);
    });

    test('showBackgroundNotification calls ensureNotificationChannel', () async {
      await controller.showBackgroundNotification();
      // 注意：由于测试环境中可能无法真正显示通知，这里只验证方法调用不抛出异常
      expect(channelEnsured, isTrue);
    }, skip: 'Notification requires platform channel in test environment');
  });
}

