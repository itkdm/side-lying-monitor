import 'package:flutter/services.dart';

/// 原生悬浮窗管理类，负责与 Android 侧服务通讯。
class FloatingWindowManager {
  static const MethodChannel _channel =
      MethodChannel('com.example.flutter_application_1/floating_window');

  /// 检查悬浮窗权限
  static Future<bool> checkOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkOverlayPermission');
      return result ?? false;
    } catch (e) {
      // ignore: avoid_print
      print('检查悬浮窗权限失败: $e');
      return false;
    }
  }

  /// 请求悬浮窗权限
  static Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      // ignore: avoid_print
      print('请求悬浮窗权限失败: $e');
    }
  }

  /// 显示悬浮窗
  static Future<bool> showFloatingWindow() async {
    try {
      final result = await _channel.invokeMethod<bool>('showFloatingWindow');
      return result ?? false;
    } catch (e) {
      // ignore: avoid_print
      print('显示悬浮窗失败: $e');
      return false;
    }
  }

  /// 隐藏悬浮窗
  static Future<bool> hideFloatingWindow() async {
    try {
      final result = await _channel.invokeMethod<bool>('hideFloatingWindow');
      return result ?? false;
    } catch (e) {
      // ignore: avoid_print
      print('隐藏悬浮窗失败: $e');
      return false;
    }
  }

  /// 更新悬浮窗状态
  static Future<bool> updateFloatingWindowState(bool isSideLying) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'updateFloatingWindowState',
        {'isSideLying': isSideLying},
      );
      return result ?? false;
    } catch (e) {
      // ignore: avoid_print
      print('更新悬浮窗状态失败: $e');
      return false;
    }
  }
}

