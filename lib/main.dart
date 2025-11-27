import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_application_1/pages/home_page.dart';
import 'package:flutter_application_1/pages/settings_page.dart';
import 'package:flutter_application_1/services/floating_window_manager.dart';
import 'package:flutter_application_1/services/permission_coordinator.dart';
import 'package:flutter_application_1/services/posture_monitor.dart';
import 'package:flutter_application_1/services/settings_repository.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

const AndroidNotificationChannel _reminderNotificationChannel =
    AndroidNotificationChannel(
  'posture_guardian_channel',
  '侧躺监测提醒',
  description: '当你侧躺玩手机时，会收到健康提醒',
  importance: Importance.high,
  playSound: true,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PostureGuardianApp());
}

/// 应用主入口，配置全局暗色玻璃拟态风格
class PostureGuardianApp extends StatelessWidget {
  const PostureGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF4361EE); // 靛青
    const background = Color(0xFF1B1B1E); // 深枪黑

    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
      primary: primaryColor,
      surface: const Color(0xFF22232A),
    );

    return MaterialApp(
      title: '枕边哨',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: background,
        fontFamily: 'Roboto',
      ),
      builder: (context, child) {
        // 配置状态栏样式，使其与首页背景一致
        // 同时确保背景色立即显示，避免空白页面
        return Container(
          color: background, // 立即显示背景色
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent, // 透明状态栏
              statusBarIconBrightness: Brightness.light, // 浅色图标（白色）
              statusBarBrightness: Brightness.dark, // iOS 状态栏样式
              systemNavigationBarColor: Color(0xFF1B1B1E), // 导航栏颜色
              systemNavigationBarIconBrightness: Brightness.light, // 导航栏图标颜色
            ),
            child: child!,
          ),
        );
      },
      home: const RootShell(),
    );
  }
}

/// 根部 Shell：管理全局状态（监测开关、设置、统计）+ 底部导航
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  // UI & 导航
  int _currentIndex = 0;

  final SettingsRepository _settingsRepo = SettingsRepository.instance;
  late final VoidCallback _settingsListener;
  bool _settingsReady = false;
  final PermissionCoordinator _permissionCoordinator = PermissionCoordinator();

  // 设置与状态
  bool _monitoring = false;
  bool _vibrationEnabled = true;
  int _thresholdSeconds = 5; // 默认从 5 秒开始更适合 MVP 体验
  TimeOfDay _dndStart = const TimeOfDay(hour: 23, minute: 0);
  TimeOfDay _dndEnd = const TimeOfDay(hour: 7, minute: 0);
  bool _dndEnabled = false;

  // 统计
  int _todayRemindCount = 0;
  DateTime _today = DateTime.now();

  // 传感器 & 姿态检测
  late final PostureMonitor _postureMonitor =
      PostureMonitor(sensorStream: accelerometerEventStream());
  StreamSubscription<PostureState>? _postureSubscription;
  bool _isSideLying = false;
  // 最近一次确认“稳定侧躺”起始时间（用于健康提醒计时）
  DateTime? _sideLyingSince;
  Timer? _checkTimer;

  static const List<int> _reminderVibrationPattern = [0, 120, 60, 120];

  // 通知服务
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isInBackground = false;
  // 提醒弹窗状态：是否正在显示
  bool _isReminderDialogShowing = false;
  
  // 悬浮窗相关（使用原生悬浮窗）
  bool _isFloatingWindowVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsListener = _handleSettingsChanged;
    _initializeNotifications();
    unawaited(_permissionCoordinator.init());
    _initSettings();
  }
  
  Future<void> _initializeNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        // 用户点击通知时的处理（可以打开 App）
      },
    );

    final androidNotifications = _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidNotifications != null) {
      // 确保后台提醒所需的通知渠道已注册（Android 8.0+ 必须调用）
      await androidNotifications
          .createNotificationChannel(_reminderNotificationChannel);
      // Android 13+ 动态通知权限
      await androidNotifications.requestNotificationsPermission();
    }
  }

  Future<void> _initSettings() async {
    await _settingsRepo.init();
    _settingsRepo.addListener(_settingsListener);
    if (!mounted) return;
    _settingsReady = true;
    _applySettingsSnapshot();
    _handleMonitoringPipeline(_monitoring);
  }

  void _handleSettingsChanged() {
    if (!mounted) return;
    final bool repoMonitoring = _settingsRepo.monitoring;
    final bool monitoringChanged = repoMonitoring != _monitoring;
    _applySettingsSnapshot();
    if (monitoringChanged) {
      _handleMonitoringPipeline(repoMonitoring);
    }
  }


  void _applySettingsSnapshot() {
    setState(() {
      _monitoring = _settingsRepo.monitoring;
      _vibrationEnabled = _settingsRepo.vibrationEnabled;
      _thresholdSeconds = _settingsRepo.thresholdSeconds;
      _dndStart = TimeOfDay(
        hour: _settingsRepo.dndStartMinutes ~/ 60,
        minute: _settingsRepo.dndStartMinutes % 60,
      );
      _dndEnd = TimeOfDay(
        hour: _settingsRepo.dndEndMinutes ~/ 60,
        minute: _settingsRepo.dndEndMinutes % 60,
      );
      _dndEnabled = _settingsRepo.dndEnabled;
      _today = _settingsRepo.today;
      _todayRemindCount = _settingsRepo.todayRemindCount;
    });
  }

  void _handleMonitoringPipeline(bool monitoringEnabled) {
    if (monitoringEnabled) {
      if (!_isInBackground && _postureSubscription == null) {
        _startSensorListening();
      }
      if (_isInBackground && !_isFloatingWindowVisible) {
        unawaited(_showFloatingWindow());
      }
    } else {
      if (_postureSubscription != null) {
        _stopSensorListening();
      }
      if (_isFloatingWindowVisible) {
        unawaited(_hideFloatingWindow());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_settingsReady) {
      _settingsRepo.removeListener(_settingsListener);
    }
    _postureSubscription?.cancel();
    unawaited(_postureMonitor.dispose());
    _checkTimer?.cancel();
    // 清理悬浮窗
    if (_isFloatingWindowVisible) {
      FloatingWindowManager.hideFloatingWindow();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 使用悬浮窗方案：当应用进入后台时，显示悬浮窗保持应用运行
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // 进入后台：如果监测开启，显示悬浮窗并启动原生服务监测
      _isInBackground = true;
      if (_monitoring) {
        // 停止Flutter层的传感器监听（避免重复）
        _stopSensorListening();
        // 显示悬浮窗（原生服务会启动传感器监听）
        if (!_isFloatingWindowVisible) {
          _showFloatingWindow();
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台：停止原生服务监测，使用Flutter层监测
      _isInBackground = false;
      // 强制隐藏悬浮窗
      if (_isFloatingWindowVisible) {
        _hideFloatingWindow();
      }
      // 确保传感器监听正在运行（Flutter层）
      if (_monitoring && _postureSubscription == null) {
        _startSensorListening();
      }
      // 重新加载统计数据（可能原生服务更新了）
      _reloadSettingsFromDisk();
    }
  }
  
  /// 显示悬浮窗（使用原生悬浮窗）
  Future<void> _showFloatingWindow() async {
    if (_isFloatingWindowVisible || !_monitoring) return;
    
    final granted =
        await _permissionCoordinator.ensureOverlayPermission(context);
    if (!granted) return;
    
    // 显示原生悬浮窗
    final success = await FloatingWindowManager.showFloatingWindow();
    if (success && mounted) {
      setState(() {
        _isFloatingWindowVisible = true;
      });
      // 更新初始状态
      FloatingWindowManager.updateFloatingWindowState(_isSideLying);
    }
  }

  /// 隐藏悬浮窗
  Future<void> _hideFloatingWindow() async {
    if (!_isFloatingWindowVisible) return;
    await FloatingWindowManager.hideFloatingWindow();
    if (mounted) {
      setState(() {
        _isFloatingWindowVisible = false;
      });
    }
  }
  
  /// 更新悬浮窗状态（当侧躺状态改变时调用）
  void _updateFloatingWindowState() {
    if (_isFloatingWindowVisible) {
      FloatingWindowManager.updateFloatingWindowState(_isSideLying);
    }
  }
  
  Future<void> _reloadSettingsFromDisk() async {
    if (!_settingsReady) return;
    await _settingsRepo.refreshFromDisk();
  }

  /// 通用轻微震动（尊重设置开关）
  Future<void> _vibrateOnce({int durationMs = 80}) async {
    if (!_vibrationEnabled) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator) {
      await Vibration.vibrate(duration: durationMs);
    }
  }

  Future<void> _vibratePattern(List<int> pattern) async {
    if (!_vibrationEnabled) return;
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator) {
      await Vibration.vibrate(pattern: pattern);
    }
  }

  void _toggleMonitoring() {
    final next = !_monitoring;
    setState(() {
      _monitoring = next;
    });
    if (next) {
      unawaited(_vibrateOnce(durationMs: 60));
    }
    _handleMonitoringPipeline(next);
    unawaited(_settingsRepo.setMonitoring(next));
  }
  
  void _startSensorListening() {
    _postureMonitor.start();
    _postureSubscription ??=
        _postureMonitor.stateStream.listen(_handlePostureState);

    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _maybeTriggerReminder();
    });
  }

  void _handlePostureState(PostureState state) {
    if (!mounted) return;
    final bool previous = _isSideLying;
    setState(() {
      _isSideLying = state.isSideLying;
      _sideLyingSince = state.sideLyingSince;
    });
    if (state.isSideLying && !previous) {
      unawaited(_vibrateOnce(durationMs: 50));
    }
    if (!_isSideLying) {
      _sideLyingSince = null;
    }
    _updateFloatingWindowState();
  }

  void _stopSensorListening() {
    _postureMonitor.stop();
    _postureSubscription?.cancel();
    _postureSubscription = null;
    _checkTimer?.cancel();
    _checkTimer = null;
    _isSideLying = false;
    _sideLyingSince = null;
    _isReminderDialogShowing = false;
  }

  bool _isInDnd(DateTime now) {
    if (!_dndEnabled) return false;
    final startMinutes = _dndStart.hour * 60 + _dndStart.minute;
    final endMinutes = _dndEnd.hour * 60 + _dndEnd.minute;
    final currentMinutes = now.hour * 60 + now.minute;

    if (startMinutes <= endMinutes) {
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;
    } else {
      // 穿越午夜，例如 23:00–07:00
      return currentMinutes >= startMinutes || currentMinutes < endMinutes;
    }
  }

  Future<void> _maybeTriggerReminder() async {
    if (!_monitoring || !_isSideLying || _sideLyingSince == null) return;

    final now = DateTime.now();

    // 新的一天重置统计
    if (now.day != _today.day ||
        now.month != _today.month ||
        now.year != _today.year) {
      setState(() {
        _today = now;
        _todayRemindCount = 0;
      });
      await _settingsRepo.resetTodayIfNeeded(now);
    }

    if (_isInDnd(now)) return;

    final elapsed = now.difference(_sideLyingSince!).inSeconds;
    if (elapsed < _thresholdSeconds) return;

    // 如果弹窗已经显示，不再重复弹出，但继续累加提醒次数和震动
    if (_isReminderDialogShowing) {
      // 继续累加提醒次数（但不在UI上显示，因为弹窗已存在）
      setState(() {
        _todayRemindCount += 1;
      });
      await _settingsRepo.incrementTodayRemindCount(at: now);
      
      // 继续震动提醒（如果可用且开启）
      await _vibratePattern(_reminderVibrationPattern);
      // 重置计时起点，等待下次阈值周期
      _sideLyingSince = now;
      return;
    }

    // 避免多次触发：重置起点，下一次需重新满足阈值
    _sideLyingSince = now;

    if (!mounted) return;

    setState(() {
      _todayRemindCount += 1;
    });
    await _settingsRepo.incrementTodayRemindCount(at: now);

    // 震动（如果可用且开启）
    await _vibratePattern(_reminderVibrationPattern);

    // 根据 App 是否在后台，选择不同的提醒方式
    if (_isInBackground || !mounted) {
      // 后台：使用通知提醒
      await _showBackgroundNotification();
    } else {
      // 前台：使用弹窗提醒
      _showReminderDialog();
    }
  }

  /// 后台时显示通知提醒
  Future<void> _showBackgroundNotification() async {
    final androidDetails = AndroidNotificationDetails(
      _reminderNotificationChannel.id,
      _reminderNotificationChannel.name,
      channelDescription: _reminderNotificationChannel.description,
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

    await _notifications.show(
      1,
      '姿势不对哦～',
      '你可能正在侧躺玩手机，注意颈椎健康哦～',
      notificationDetails,
    );
  }

  void _showReminderDialog() {
    // 如果弹窗已经显示，不再重复弹出
    if (_isReminderDialogShowing) return;
    
    setState(() {
      _isReminderDialogShowing = true;
    });
    
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
            // 毛玻璃背景
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.4),
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
                      // 用户点击"知道了"后，重置状态，允许下次提醒
                      setState(() {
                        _isReminderDialogShowing = false;
                        // 重置侧躺计时起点，这样用户如果继续保持侧躺，需要重新满足阈值才会再次提醒
                        _sideLyingSince = DateTime.now();
                      });
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
      if (mounted) {
        setState(() {
          _isReminderDialogShowing = false;
          // 重置侧躺计时起点
          _sideLyingSince = DateTime.now();
        });
      }
    });
  }


  // —— 设置项的更新回调 ——

  void _updateVibration(bool value) {
    setState(() {
      _vibrationEnabled = value;
    });
    unawaited(_settingsRepo.setVibrationEnabled(value));
  }

  void _updateThreshold(double value) {
    setState(() {
      _thresholdSeconds = value.round();
    });
    unawaited(_settingsRepo.setThresholdSeconds(_thresholdSeconds));
  }

  void _updateDndStart(TimeOfDay value) {
    setState(() {
      _dndStart = value;
    });
    final minutes = value.hour * 60 + value.minute;
    unawaited(_settingsRepo.setDndStartMinutes(minutes));
  }

  void _updateDndEnd(TimeOfDay value) {
    setState(() {
      _dndEnd = value;
    });
    final minutes = value.hour * 60 + value.minute;
    unawaited(_settingsRepo.setDndEndMinutes(minutes));
  }

  void _updateDndEnabled(bool value) {
    setState(() {
      _dndEnabled = value;
    });
    unawaited(_settingsRepo.setDndEnabled(value));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        monitoring: _monitoring,
        isSideLying: _isSideLying,
        remindCount: _todayRemindCount,
        thresholdSeconds: _thresholdSeconds,
        onToggleMonitoring: _toggleMonitoring,
      ),
      SettingsPage(
        vibrationEnabled: _vibrationEnabled,
        thresholdSeconds: _thresholdSeconds,
        dndStart: _dndStart,
        dndEnd: _dndEnd,
        dndEnabled: _dndEnabled,
        onVibrationChanged: _updateVibration,
        onThresholdChanged: _updateThreshold,
        onDndStartChanged: _updateDndStart,
        onDndEndChanged: _updateDndEnd,
        onDndEnabledChanged: _updateDndEnabled,
      ),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: _FrostedBottomNavBar(
        currentIndex: _currentIndex,
        onIndexChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}

/// 底部导航栏，带轻微放大与上浮效果
class _FrostedBottomNavBar extends StatelessWidget {
  const _FrostedBottomNavBar({
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    const items = [
      _NavItem(icon: Icons.home_rounded, label: '首页'),
      _NavItem(icon: Icons.settings_rounded, label: '设置'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(
              color: Colors.white.withValues(alpha: 0.14),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(items.length, (index) {
                final selected = index == currentIndex;
                final item = items[index];
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => onIndexChanged(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      transform: selected
                          ? Matrix4.translationValues(0, -4, 0)
                          : Matrix4.identity(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            item.icon,
                            size: selected ? 26 : 22,
                            color: selected
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 4),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                              color: selected
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.6),
                            ),
                            child: Text(item.label),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// 免打扰时间选择器小卡片
/// 提醒弹窗内容卡片
// 注意：旧的Flutter Overlay悬浮窗组件已移除，现在使用原生Android悬浮窗
// 原生悬浮窗可以在其他应用上显示，提供更好的后台监测体验


