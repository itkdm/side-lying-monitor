import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 全局错误处理器
class ErrorHandler {
  ErrorHandler._();
  static final ErrorHandler instance = ErrorHandler._();

  /// 处理错误并显示用户友好的提示
  static void handleError(
    Object error,
    StackTrace? stackTrace, {
    String? userMessage,
    bool showToUser = false,
    BuildContext? context,
  }) {
    // 记录错误日志
    debugPrint('Error: $error');
    if (stackTrace != null) {
      debugPrint('StackTrace: $stackTrace');
    }

    // 如果需要在UI上显示错误
    if (showToUser && context != null) {
      _showErrorDialog(context, userMessage ?? '发生了一个错误，请稍后重试');
    }
  }

  /// 显示错误对话框
  static void _showErrorDialog(BuildContext context, String message) {
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF22232A),
        title: const Text(
          '错误',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 处理异步操作错误
  static Future<T?> safeAsync<T>(
    Future<T> Function() operation, {
    T? defaultValue,
    String? errorMessage,
  }) async {
    try {
      return await operation();
    } catch (e, stackTrace) {
      handleError(e, stackTrace, userMessage: errorMessage);
      return defaultValue;
    }
  }
}

