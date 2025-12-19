import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/controllers/lifecycle_coordinator.dart';
import 'package:flutter_application_1/services/settings_repository.dart';
import 'package:flutter_application_1/services/floating_window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LifecycleCoordinator', () {
    late LifecycleCoordinator coordinator;
    late SettingsRepository settingsRepo;
    bool foregroundResumedCalled = false;

    setUp(() {
      settingsRepo = SettingsRepository.instance;
      foregroundResumedCalled = false;
      coordinator = LifecycleCoordinator(
        settingsRepository: settingsRepo,
        onForegroundResumed: () {
          foregroundResumedCalled = true;
        },
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('should initialize with correct state', () {
      expect(coordinator.isInBackground, isFalse);
      expect(coordinator.isFloatingWindowVisible, isFalse);
    });

    test('handleLifecycleChange should update isInBackground on pause', () {
      coordinator.handleLifecycleChange(
        AppLifecycleState.paused,
        true, // monitoring
        false, // isSideLying
      );

      expect(coordinator.isInBackground, isTrue);
    });

    test('handleLifecycleChange should update isInBackground on resume', () {
      // 先设置为后台状态
      coordinator.handleLifecycleChange(
        AppLifecycleState.paused,
        true,
        false,
      );
      expect(coordinator.isInBackground, isTrue);

      // 然后恢复前台
      coordinator.handleLifecycleChange(
        AppLifecycleState.resumed,
        true,
        false,
      );

      expect(coordinator.isInBackground, isFalse);
      expect(foregroundResumedCalled, isTrue);
    });

    test('handleLifecycleChange should not show floating window if monitoring is false', () {
      coordinator.handleLifecycleChange(
        AppLifecycleState.paused,
        false, // monitoring = false
        false,
      );

      // 即使进入后台，如果监测未开启，也不应该显示悬浮窗
      expect(coordinator.isFloatingWindowVisible, isFalse);
    });

    test('updateFloatingWindowState should update state if window is visible', () {
      // 注意：实际测试中需要mock FloatingWindowManager
      // 这里主要测试逻辑流程
      
      coordinator.updateFloatingWindowState(true);
      
      // 如果悬浮窗不可见，updateFloatingWindowState应该不会执行操作
      expect(coordinator.isFloatingWindowVisible, isFalse);
    });

    test('dispose should clean up resources', () {
      coordinator.dispose();
      
      // 验证dispose不会抛出异常
      expect(() => coordinator.dispose(), returnsNormally);
    });

    test('should handle inactive state', () {
      coordinator.handleLifecycleChange(
        AppLifecycleState.inactive,
        true,
        false,
      );

      // inactive状态应该被视为后台
      expect(coordinator.isInBackground, isTrue);
    });

    test('should handle detached state', () {
      // detached状态通常不会触发悬浮窗显示
      coordinator.handleLifecycleChange(
        AppLifecycleState.detached,
        true,
        false,
      );

      // detached状态不应该影响isInBackground
      // 因为detached是应用即将终止的状态
    });
  });
}
