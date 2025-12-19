import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_application_1/services/error_handler.dart';
import 'package:flutter_application_1/utils/logger.dart';

/// 提醒控制器：负责处理侧躺提醒逻辑（震动、通知、弹窗）
class ReminderController {
  ReminderController({
    required FlutterLocalNotificationsPlugin notifications,
    required VoidCallback ensureNotificationChannel,
  })  : _notifications = notifications,
        _ensureNotificationChannel = ensureNotificationChannel;

  final FlutterLocalNotificationsPlugin _notifications;
  final VoidCallback _ensureNotificationChannel;

  static const List<int> _reminderVibrationPattern = [0, 120, 60, 120];
  bool _isReminderDialogShowing = false;

  bool get isReminderDialogShowing => _isReminderDialogShowing;

  /// 通用轻微震动（尊重设置开关）
  Future<void> vibrateOnce({int durationMs = 80, bool enabled = true}) async {
    if (!enabled) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator) {
      await Vibration.vibrate(duration: durationMs);
    }
  }

  /// 震动模式
  Future<void> vibratePattern(List<int> pattern, {bool enabled = true}) async {
    if (!enabled) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator) {
      await Vibration.vibrate(pattern: pattern);
    }
  }

  /// 触发提醒（震�?+ 通知/弹窗�?
  Future<void> triggerReminder({
    required BuildContext context,
    required bool isInBackground,
    required bool vibrationEnabled,
    required VoidCallback onDialogClosed,
  }) async {
    // 震动提醒
    await vibratePattern(_reminderVibrationPattern, enabled: vibrationEnabled);

    // 根据 App 是否在后台，选择不同的提醒方�?
    if (isInBackground) {
      // 后台：使用通知提醒
      await showBackgroundNotification();
    } else {
      // 前台：使用弹窗提�?
      showReminderDialog(context, onDialogClosed);
    }
  }

  /// 后台时显示通知提醒
  Future<void> showBackgroundNotification() async {
    // 确保通知渠道已注�?
    _ensureNotificationChannel();

    // 使用与main.dart中相同的渠道ID常量
    const androidDetails = AndroidNotificationDetails(
      'posture_guardian_channel', // 与_RootShellState._notificationChannelId保持一�?
      '侧躺监测提醒',
      channelDescription: '当你侧躺玩手机时，会收到健康提醒',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      await _notifications.show(
        1,
        '姿势不对哦～',
        '你可能正在侧躺玩手机，注意颈椎健康哦～',
        notificationDetails,
      );
    } catch (e, stackTrace) {
      // 如果通知发送失败，记录错误但不影响应用运行
      AppLogger.e('ReminderController', '显示通知失败', e, stackTrace);
      ErrorHandler.handleError(e, stackTrace, userMessage: '发送提醒通知失败');
    }
  }

  /// 显示提醒弹窗
  void showReminderDialog(BuildContext context, VoidCallback onDialogClosed) {
    // 如果弹窗已经显示，不再重复弹�?
    if (_isReminderDialogShowing) return;

    _isReminderDialogShowing = true;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '提醒',
      pageBuilder: (context, animation, secondaryAnimation) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (context, animation, secondary, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return Stack(
          children: [
            // 毛玻璃背�?
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  color: Colors.black.withOpacity(0.45),
                ),
              ),
            ),
            Center(
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
                  child: ReminderDialog(
                    onClose: () {
                      Navigator.of(context).pop();
                      _isReminderDialogShowing = false;
                      onDialogClosed();
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      // 对话框关闭时的回调（无论是点击按钮还是点击外部关闭）
      _isReminderDialogShowing = false;
      onDialogClosed();
    });
  }

  /// 重置提醒状�?
  void reset() {
    _isReminderDialogShowing = false;
  }
}

/// 提醒弹窗内容卡片
class ReminderDialog extends StatelessWidget {
  const ReminderDialog({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.78,
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.6),
                Colors.white.withOpacity(0.6),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: Color(0xFFFF8A80), // 暖珊瑚色近似
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.hotel_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '姿势不对哦～',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: const Color(0xFF333333),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '你可能正侧躺玩手机，试着稍微调整一下姿势，给颈椎一点温柔。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF555555),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '可在设置中调整提醒时间和免打扰时段。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF888888),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onClose,
                  child: const Text(
                    '知道了',
                    style: TextStyle(
                      color: Color(0xFF4361EE),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

