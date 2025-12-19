import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_application_1/services/error_handler.dart';
import 'package:flutter_application_1/services/posture_monitor.dart';
import 'package:flutter_application_1/utils/logger.dart';

/// 从原生服务接收姿态检测状态的流
/// 统一使用原生服务进行检测，Flutter层仅负责UI展示
class NativePostureStream {
  NativePostureStream._();
  static final NativePostureStream instance = NativePostureStream._();

  static const EventChannel _eventChannel =
      EventChannel('com.example.flutter_application_1/posture_events');

  StreamSubscription<dynamic>? _subscription;
  final StreamController<PostureState> _stateController =
      StreamController<PostureState>.broadcast();
  final StreamController<int> _statsController =
      StreamController<int>.broadcast();

  /// 姿态状态流
  Stream<PostureState> get stateStream => _stateController.stream;
  
  /// 统计数据流（今日提醒次数）
  Stream<int> get statsStream => _statsController.stream;

  /// 开始监听原生服务推送的姿态状态
  void startListening() {
    if (_subscription != null) return;

    try {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          try {
            if (event is Map) {
              final type = event['type'] as String?;
              
              if (type == 'stats') {
                // 统计数据事件（频率较低，不额外打调试日志）
                final count = event['todayRemindCount'] as int? ?? 0;
                if (!_statsController.isClosed) {
                  _statsController.add(count);
                }
              } else {
                // 姿态状态事件
                final isSideLying = event['isSideLying'] as bool? ?? false;
                final sideLyingSinceTimestamp = event['sideLyingSince'] as int?;
                
                final sideLyingSince = sideLyingSinceTimestamp != null && sideLyingSinceTimestamp > 0
                    ? DateTime.fromMillisecondsSinceEpoch(sideLyingSinceTimestamp)
                    : null;

                final state = PostureState(
                  isSideLying: isSideLying,
                  sideLyingSince: sideLyingSince,
                );

                if (!_stateController.isClosed) {
                  _stateController.add(state);
                }
              }
            }
          } catch (e, stackTrace) {
            // 解析错误，记录但不中断流
            ErrorHandler.handleError(e, stackTrace, userMessage: '解析姿态事件失败');
          }
        },
        onError: (error) {
          // 流错误处理
          ErrorHandler.handleError(error, null, userMessage: '姿态检测流错误');
          // 可以选择重连或通知用户
        },
        cancelOnError: false, // 不因错误取消订阅
      );
    } catch (e, stackTrace) {
      AppLogger.e('NativePostureStream', '启动原生姿态流失败', e, stackTrace);
      ErrorHandler.handleError(e, stackTrace, userMessage: '启动姿态检测服务失败');
    }
  }

  /// 停止监听
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// 清理资源
  Future<void> dispose() async {
    stopListening();
    await _stateController.close();
    await _statsController.close();
  }
}

