import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_application_1/controllers/lifecycle_coordinator.dart';
import 'package:flutter_application_1/controllers/reminder_controller.dart';
import 'package:flutter_application_1/pages/home_page.dart';
import 'package:flutter_application_1/pages/settings_page.dart';
import 'package:flutter_application_1/services/error_handler.dart';
import 'package:flutter_application_1/services/native_posture_stream.dart';
import 'package:flutter_application_1/services/permission_coordinator.dart';
import 'package:flutter_application_1/services/posture_monitor.dart';
import 'package:flutter_application_1/services/settings_repository.dart';
import 'package:flutter_application_1/services/custom_posture_repository.dart';
import 'package:flutter_application_1/services/floating_window_manager.dart';
import 'package:flutter_application_1/utils/logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PostureGuardianApp());
}

/// 应用主入口，配置全局暗色玻璃拟态风�?
class PostureGuardianApp extends StatelessWidget {
  const PostureGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF4361EE); // 靛青
    const background = Color(0xFF1B1B1E); // 深枪�?

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
        // 配置状态栏样式，使其与首页背景一�?
        // 同时确保背景色立即显示，避免空白页面
        return Container(
          color: background, // 立即显示背景�?
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent, // 透明状态栏
              statusBarIconBrightness: Brightness.light, // 浅色图标（白色）
              statusBarBrightness: Brightness.dark, // iOS 状态栏样式
              systemNavigationBarColor: Color(0xFF1B1B1E), // 导航栏颜�?
              systemNavigationBarIconBrightness: Brightness.light, // 导航栏图标颜�?
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

  // 设置与状�?
  bool _monitoring = false;
  bool _vibrationEnabled = true;
  int _thresholdSeconds = 5; // 默认�?5 秒开始更适合 MVP 体验
  TimeOfDay _dndStart = const TimeOfDay(hour: 23, minute: 0);
  TimeOfDay _dndEnd = const TimeOfDay(hour: 7, minute: 0);
  bool _dndEnabled = false;

  // 统计
  int _todayRemindCount = 0;
  DateTime _today = DateTime.now();

  // 姿态检测：统一使用原生服务
  final NativePostureStream _nativePostureStream = NativePostureStream.instance;
  StreamSubscription<PostureState>? _postureSubscription;
  StreamSubscription<int>? _statsSubscription;
  bool _isSideLying = false;
  // 最近一次确�?稳定侧躺"起始时间（用于健康提醒计时）
  DateTime? _sideLyingSince;
  // 前台提醒检查定时器（仅用于在前台根据服务提供的 sideLyingSince 弹出对话框）
  Timer? _checkTimer;

  // 通知服务
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  // 自定义姿势
  final CustomPostureRepository _customPostureRepository =
      CustomPostureRepository.instance;

  // 控制�?
  late final ReminderController _reminderController;
  late final LifecycleCoordinator _lifecycleCoordinator;
  bool _nativeMonitoringEnsured = false; // 确保原生服务已启动

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsListener = _handleSettingsChanged;
    unawaited(_permissionCoordinator.init());
    _initializeControllersAndSettings();
  }
  
  /// 初始化控制器和设置（确保顺序）
  Future<void> _initializeControllersAndSettings() async {
    try {
      await _initializeControllers();
      await _initSettings();
      AppLogger.d('RootShell', 'Initialization complete');
    } catch (e, stackTrace) {
      AppLogger.e('RootShell', 'Initialization failed', e, stackTrace);
      ErrorHandler.handleError(e, stackTrace, userMessage: '应用初始化失败');
    }
  }

  Future<void> _initializeControllers() async {
    await _initializeNotifications();
    
    // 初始化自定义姿势仓库
    try {
      await CustomPostureRepository.instance.init();
    } catch (e, stackTrace) {
      AppLogger.e('RootShell', 'Failed to init custom posture repository', e, stackTrace);
      // 继续初始化，不阻塞
    }
    
    // 初始化提醒控制器
    _reminderController = ReminderController(
      notifications: _notifications,
      ensureNotificationChannel: _ensureNotificationChannel,
    );
    
    // 初始化生命周期协调器（不再需要PostureMonitor，统一使用原生服务�?
    _lifecycleCoordinator = LifecycleCoordinator(
      settingsRepository: _settingsRepo,
      onForegroundResumed: () {
        // 回到前台时的回调
        if (mounted) {
          setState(() {
            // 触发UI更新
          });
        }
      },
    );
    
    // 开始监听原生服务推送的姿态状�?
    _nativePostureStream.startListening();
    _postureSubscription = _nativePostureStream.stateStream.listen(
      _handlePostureState,
      onError: (error, stackTrace) {
        AppLogger.e('RootShell', '姿态检测服务异常', error, stackTrace);
        ErrorHandler.handleError(error, stackTrace, userMessage: '姿态检测服务异常');
      },
    );
    
    // 监听统计数据更新（原生服务推送的统计数据
    _statsSubscription = _nativePostureStream.statsStream.listen(
      (count) {
        if (mounted) {
          setState(() {
            _todayRemindCount = count;
          });
          // 统计数据仅用于展示，不再在这里触发前台弹窗
        }
      },
      onError: (error, stackTrace) {
        AppLogger.e('RootShell', '统计数据流错误', error, stackTrace);
        ErrorHandler.handleError(error, stackTrace);
      },
    );
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
        // 用户点击通知时的处理（可以打开 App
      },
    );

    // 确保通知渠道在所有场景下都正确注
    await _ensureNotificationChannel();
  }

  /// 确保通知渠道已注册（可在多个地方调用，确保不会重复创建）
  /// 使用统一的渠道ID常量，避免不一
  static const String _notificationChannelId = 'posture_guardian_channel';
  static const String _notificationChannelName = '侧躺监测提醒';
  static const String _notificationChannelDescription = '当你侧躺玩手机时，会收到健康提醒';
  
  // 缓存通知渠道检查结果，避免重复查询
  static bool? _notificationChannelChecked;
  
  Future<void> _ensureNotificationChannel() async {
    // 如果已经检查过且存在，直接返回（避免重复查询）
    if (_notificationChannelChecked == true) return;
    
    final androidNotifications = _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidNotifications != null) {
      try {
        // 检查渠道是否已存在，避免重复创
        final existingChannels = await androidNotifications.getNotificationChannels();
        final channelExists = existingChannels?.any(
          (channel) => channel.id == _notificationChannelId,
        ) ?? false;
        
        if (!channelExists) {
          // 确保后台提醒所需的通知渠道已注册（Android 8.0+ 必须调用
          const channel = AndroidNotificationChannel(
            _notificationChannelId,
            _notificationChannelName,
            description: _notificationChannelDescription,
            importance: Importance.high,
            playSound: true,
          );
          await androidNotifications.createNotificationChannel(channel);
          AppLogger.d('RootShell', '通知渠道已创建 $_notificationChannelId');
        } else {
          // 只在第一次检查时输出日志，避免重复输出
          if (_notificationChannelChecked == null) {
            AppLogger.d('RootShell', '通知渠道已存在 $_notificationChannelId');
          }
        }
        
        // 标记已检查
        _notificationChannelChecked = true;
        
        // Android 13+ 动态通知权限
        await androidNotifications.requestNotificationsPermission();
      } catch (e, stackTrace) {
        // 如果注册失败，记录错误但不影响应用启�?
        AppLogger.e('RootShell', '创建通知渠道失败', e, stackTrace);
        ErrorHandler.handleError(e, stackTrace, userMessage: '通知渠道注册失败');
      }
    }
  }

  Future<void> _initSettings() async {
    await _settingsRepo.init();
    _settingsRepo.addListener(_settingsListener);
    if (!mounted) {
      AppLogger.d('RootShell', 'Widget not mounted, skipping settings apply');
      return;
    }
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
    // 同步自定义姿势开关到仓库（异步，不阻塞UI）
    unawaited(_customPostureRepository.setUseCustomPostures(_settingsRepo.useCustomPostures));
  }

  void _handleMonitoringPipeline(bool monitoringEnabled) {
    if (monitoringEnabled) {
      // 确保原生前台服务已经启动（即使还在 App 前台）
      _ensureNativeMonitoringStarted();
      // 前台：启动前台定时器，仅用于根据服务提供的 sideLyingSince 弹出对话框
      if (!_lifecycleCoordinator.isInBackground) {
        _startForegroundReminderCheck();
      }
      if (_lifecycleCoordinator.isInBackground && !_lifecycleCoordinator.isFloatingWindowVisible) {
        // 显示悬浮窗由 LifecycleCoordinator 管理，这里触发生命周期检�?
        _lifecycleCoordinator.handleLifecycleChange(
          AppLifecycleState.paused,
          monitoringEnabled,
          _isSideLying,
        );
      }
    } else {
      // 关闭前台定时器
      _stopForegroundReminderCheck();
      if (_lifecycleCoordinator.isFloatingWindowVisible) {
        _lifecycleCoordinator.handleLifecycleChange(
          AppLifecycleState.resumed,
          monitoringEnabled,
          _isSideLying,
        );
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
    _statsSubscription?.cancel();
    unawaited(_nativePostureStream.dispose());
    _stopForegroundReminderCheck();
    _lifecycleCoordinator.dispose();
    _reminderController.reset();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 使用生命周期协调器处理前后台切换
    _lifecycleCoordinator.handleLifecycleChange(
      state,
      _monitoring,
      _isSideLying,
    );

    // 根据前后台状态启动/停止前台提醒定时器
    if (state == AppLifecycleState.resumed) {
      if (_monitoring) {
        _startForegroundReminderCheck();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _stopForegroundReminderCheck();
    }
  }

  void _toggleMonitoring() {
    final next = !_monitoring;
    setState(() {
      _monitoring = next;
    });
    if (next) {
      unawaited(_reminderController.vibrateOnce(
          durationMs: 60, enabled: _vibrationEnabled));
      // 监测从关闭切换为开启时，确保原生服务已启动
      _ensureNativeMonitoringStarted();
    }
    _handleMonitoringPipeline(next);
    unawaited(_settingsRepo.setMonitoring(next));
  }

  /// 前台定时器：每秒检查一次是否需要在前台弹出对话框（不影响服务端逻辑）
  void _startForegroundReminderCheck() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _maybeShowForegroundReminder();
    });
  }

  void _stopForegroundReminderCheck() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  /// 确保原生监测服务已启动：
  /// - 若尚未启动，则通过显示/隐藏悬浮窗的方式启动前台服务和传感器监听；
  /// - 若启动失败，不会抛异常，只记录日志。
  void _ensureNativeMonitoringStarted() {
    if (_nativeMonitoringEnsured) return;
    unawaited(() async {
      try {
        final shown = await FloatingWindowManager.showFloatingWindow();
        _nativeMonitoringEnsured = true;
      } catch (e, stackTrace) {
        AppLogger.e('RootShell', 'Failed to ensure native monitoring service', e, stackTrace);
      }
    }());
  }

  void _handlePostureState(PostureState state) {
    if (!mounted) return;
    final bool previous = _isSideLying;
    setState(() {
      _isSideLying = state.isSideLying;
      _sideLyingSince = state.sideLyingSince;
    });
    if (state.isSideLying && !previous) {
      // 刚开始侧躺，轻微震动提示
      unawaited(_reminderController.vibrateOnce(durationMs: 50, enabled: _vibrationEnabled));
      AppLogger.d('RootShell', 'Side lying started, starting reminder check');
    }
    
    if (!_isSideLying) {
      _sideLyingSince = null;
      AppLogger.d('RootShell', 'Side lying ended, resetting timer');
    }
    
    _lifecycleCoordinator.updateFloatingWindowState(_isSideLying);
  }

  void _stopSensorListening() {
    // Flutter 端不再直接监听传感器，仅重置本地姿态/提醒状态
    _checkTimer?.cancel();
    _checkTimer = null;
    _isSideLying = false;
    _sideLyingSince = null;
    _reminderController.reset();
  }

  bool _isInDnd(DateTime now) {
    if (!_dndEnabled) return false;
    final startMinutes = _dndStart.hour * 60 + _dndStart.minute;
    final endMinutes = _dndEnd.hour * 60 + _dndEnd.minute;
    final currentMinutes = now.hour * 60 + now.minute;

    if (startMinutes <= endMinutes) {
      return currentMinutes >= startMinutes && currentMinutes < endMinutes;
    } else {
      // 穿越午夜，例�?23:00�?7:00
      return currentMinutes >= startMinutes || currentMinutes < endMinutes;
    }
  }
  
  /// 仅在前台时，根据服务提供的 sideLyingSince 与本地阈值，决定是否弹出前台对话框。
  /// 不修改统计次数，也不写入 SharedPreferences，统计仍由服务负责。
  Future<void> _maybeShowForegroundReminder() async {
    if (!_monitoring ||
        !_isSideLying ||
        _sideLyingSince == null ||
        _lifecycleCoordinator.isInBackground) {
      return;
    }

    final now = DateTime.now();

    if (_isInDnd(now)) {
      return;
    }

    final elapsed = now.difference(_sideLyingSince!).inSeconds;
    if (elapsed < _thresholdSeconds) {
      return;
    }

    // 避免重复弹出多个对话框
    if (_reminderController.isReminderDialogShowing) {
      return;
    }

    if (!mounted) return;

    await _reminderController.triggerReminder(
      context: context,
      isInBackground: false,
      vibrationEnabled: _vibrationEnabled,
      onDialogClosed: () {
        // 关闭后，从现在重新计时，避免立刻再次触发
        _sideLyingSince = DateTime.now();
      },
    );
  }


  // —�?设置项的更新回调 —�?

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

  void _updateUseCustomPostures(bool value) {
    // 同步到本地设置与自定义姿势仓库
    unawaited(_customPostureRepository.setUseCustomPostures(value));
    unawaited(_settingsRepo.setUseCustomPostures(value));
  }

  @override
  Widget build(BuildContext context) {
    AppLogger.d('RootShell', '=== build() called ===');
    AppLogger.d('RootShell', 'Current index: $_currentIndex, monitoring: $_monitoring, remindCount: $_todayRemindCount');
    
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
        useCustomPostures: _customPostureRepository.useCustomPostures,
        onUseCustomPosturesChanged: _updateUseCustomPostures,
      ),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: _FrostedBottomNavBar(
        currentIndex: _currentIndex,
        onIndexChanged: (index) {
          AppLogger.d('RootShell', '=== Navigation changed ===');
          AppLogger.d('RootShell', 'Current index: $_currentIndex -> New index: $index');
          try {
            setState(() {
              _currentIndex = index;
            });
            AppLogger.d('RootShell', 'Navigation setState completed');
          } catch (e, stackTrace) {
            AppLogger.e('RootShell', 'Error in navigation setState', e, stackTrace);
          }
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
            color: Colors.black.withOpacity(0.45),
              border: Border.all(
              color: Colors.white.withOpacity(0.14),
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
                    onTap: () {
                      AppLogger.d('RootShell', '=== Navigation item tapped ===');
                      AppLogger.d('RootShell', 'Tapped index: $index, current: $currentIndex');
                      onIndexChanged(index);
                    },
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
                                : Colors.white.withOpacity(0.6),
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
                                  : Colors.white.withOpacity(0.6),
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
// 注意：旧的Flutter Overlay悬浮窗组件已移除，现在使用原生Android悬浮�?
// 原生悬浮窗可以在其他应用上显示，提供更好的后台监测体�?


