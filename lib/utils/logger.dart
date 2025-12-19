import 'package:flutter/foundation.dart';

/// 统一的日志工具类
/// 根据构建类型控制日志输出，提升生产环境性能
class AppLogger {
  AppLogger._();

  /// Debug级别日志（仅在Debug模式下输出）
  static void d(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] $message');
    }
  }

  /// Info级别日志（仅在Debug模式下输出）
  static void i(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] INFO: $message');
    }
  }

  /// Warning级别日志（仅在Debug模式下输出）
  static void w(String tag, String message) {
    if (kDebugMode) {
      debugPrint('[$tag] WARN: $message');
    }
  }

  /// Error级别日志（Release模式下也记录错误）
  static void e(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    // Release模式下也记录错误，但不输出详细信息
    debugPrint('[$tag] ERROR: $message');
    if (error != null && kDebugMode) {
      debugPrint('[$tag] Error details: $error');
      if (stackTrace != null) {
        debugPrint('[$tag] StackTrace: $stackTrace');
      }
    }
  }
}

