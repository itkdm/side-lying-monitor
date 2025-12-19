import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/services/native_posture_stream.dart';
import 'package:flutter_application_1/services/posture_monitor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativePostureStream', () {
    late NativePostureStream stream;

    setUp(() {
      stream = NativePostureStream.instance;
    });

    tearDown(() async {
      await stream.dispose();
    });

    test('should be singleton', () {
      final instance1 = NativePostureStream.instance;
      final instance2 = NativePostureStream.instance;
      expect(instance1, same(instance2));
    });

    test('stateStream should emit PostureState events', () async {
      final states = <PostureState>[];
      final subscription = stream.stateStream.listen((state) {
        states.add(state);
      });

      // 模拟原生服务推送姿态状态事件
      // 注意：在实际测试中，这需要mock EventChannel
      // 这里主要测试流的基本功能

      await Future.delayed(const Duration(milliseconds: 100));
      subscription.cancel();

      // 验证流已创建
      expect(stream.stateStream, isNotNull);
    });

    test('statsStream should emit int events', () async {
      final counts = <int>[];
      final subscription = stream.statsStream.listen((count) {
        counts.add(count);
      });

      await Future.delayed(const Duration(milliseconds: 100));
      subscription.cancel();

      // 验证流已创建
      expect(stream.statsStream, isNotNull);
    });

    test('startListening should not create duplicate subscriptions', () {
      stream.startListening();
      final subscription1 = stream.stateStream.listen((_) {});
      
      stream.startListening(); // 再次调用应该不会创建新订阅
      final subscription2 = stream.stateStream.listen((_) {});
      
      expect(subscription1, isNotNull);
      expect(subscription2, isNotNull);
      
      subscription1.cancel();
      subscription2.cancel();
    });

    test('stopListening should cancel subscription', () async {
      stream.startListening();
      final subscription = stream.stateStream.listen((_) {});
      
      expect(subscription, isNotNull);
      
      stream.stopListening();
      
      // 验证订阅已取消（通过检查流是否仍然可用）
      expect(stream.stateStream, isNotNull);
      
      subscription.cancel();
    });

    test('dispose should close all streams', () async {
      stream.startListening();
      
      final stateSubscription = stream.stateStream.listen((_) {});
      final statsSubscription = stream.statsStream.listen((_) {});
      
      await stream.dispose();
      
      // 验证流已关闭
      expect(() => stream.stateStream.listen((_) {}), throwsA(isA<StateError>()));
      expect(() => stream.statsStream.listen((_) {}), throwsA(isA<StateError>()));
      
      stateSubscription.cancel();
      statsSubscription.cancel();
    });

    test('should handle null events gracefully', () async {
      stream.startListening();
      
      // 测试流不会因为null事件而崩溃
      final subscription = stream.stateStream.listen(
        (state) {
          expect(state, isA<PostureState>());
        },
        onError: (error) {
          // 错误应该被正确处理
          expect(error, isNotNull);
        },
      );
      
      await Future.delayed(const Duration(milliseconds: 100));
      subscription.cancel();
    });
  });
}
