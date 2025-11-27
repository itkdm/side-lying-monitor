import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_application_1/services/settings_repository.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

/// 原生悬浮窗管理类
class FloatingWindowManager {
  static const MethodChannel _channel = MethodChannel('com.example.flutter_application_1/floating_window');

  /// 检查悬浮窗权限
  static Future<bool> checkOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkOverlayPermission');
      return result ?? false;
    } catch (e) {
      print('检查悬浮窗权限失败: $e');
      return false;
    }
  }

  /// 请求悬浮窗权限
  static Future<void> requestOverlayPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } catch (e) {
      print('请求悬浮窗权限失败: $e');
    }
  }

  /// 显示悬浮窗
  static Future<bool> showFloatingWindow() async {
    try {
      final result = await _channel.invokeMethod<bool>('showFloatingWindow');
      return result ?? false;
    } catch (e) {
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
      print('更新悬浮窗状态失败: $e');
      return false;
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _initializeBackgroundService();
  runApp(const PostureGuardianApp());
}

/// 初始化后台服务
Future<void> _initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'posture_guardian_service',
      initialNotificationTitle: '枕边哨',
      initialNotificationContent: '正在后台监测你的姿势',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

/// iOS 后台回调
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

/// 后台服务启动回调
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // 如果是 Android，设置为前台服务
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  // 初始化通知插件（在后台服务中）
  final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await notifications.initialize(initSettings);

  // 在后台服务中保持传感器监听
  StreamSubscription<AccelerometerEvent>? accelSub;
  Timer? checkTimer;
  
  // 从 SharedPreferences 读取设置
  final prefs = await SharedPreferences.getInstance();
  bool vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
  int thresholdSeconds = prefs.getInt('threshold_seconds') ?? 5;
  
  // 侧躺检测状态
  bool isSideLying = false;
  DateTime? sideLyingSince;
  DateTime? sideCandidateSince;
  double? lastG;
  double avgNx = 0;
  double avgNy = 0;
  double avgNz = 1;
  double avgG = 9.8;

  // 开始传感器监听
  accelSub = accelerometerEvents.listen((event) {
    try {
      final ax = event.x;
      final ay = event.y;
      final az = event.z;
      final g = sqrt(ax * ax + ay * ay + az * az);

      if (g < 1e-3) return;

      final nx = ax / g;
      final ny = ay / g;
      final nz = az / g;

      const alpha = 0.15;
      avgNx = alpha * nx + (1 - alpha) * avgNx;
      avgNy = alpha * ny + (1 - alpha) * avgNy;
      avgNz = alpha * nz + (1 - alpha) * avgNz;
      avgG = alpha * g + (1 - alpha) * avgG;

      double deltaG = 0;
      if (lastG != null) {
        deltaG = (g - lastG!).abs();
      }
      lastG = g;

      if (deltaG > 0.8) {
        sideCandidateSince = null;
        if (isSideLying) {
          isSideLying = false;
          sideLyingSince = null;
        }
      }

      final bool isScreenRoughlyVertical = avgNz.abs() < 0.8;
      final bool isGravityMostlySide = avgNx.abs() > 0.4 || avgNy.abs() > 0.4;
      final bool isSideByDirection = isScreenRoughlyVertical && isGravityMostlySide;
      final bool isSideByRaw = ax.abs() > 6.5 && az.abs() < 5.0;
      final isSide = isSideByDirection || isSideByRaw;

      final now = DateTime.now();

      if (isSide) {
        sideCandidateSince ??= now;
        final stableDuration = now.difference(sideCandidateSince!).inSeconds;
        const stableThresholdSeconds = 2;
        if (!isSideLying && stableDuration >= stableThresholdSeconds) {
          isSideLying = true;
          sideLyingSince = now;
        }
      } else {
        sideCandidateSince = null;
        isSideLying = false;
        sideLyingSince = null;
      }
    } catch (e) {
      // 捕获传感器错误，防止服务崩溃
      print('Sensor error in background service: $e');
    }
  });

  // 检查是否在免打扰时段
  bool isInDnd(DateTime now, int dndStartMinutes, int dndEndMinutes) {
    final currentMinutes = now.hour * 60 + now.minute;
    if (dndStartMinutes <= dndEndMinutes) {
      return currentMinutes >= dndStartMinutes && currentMinutes < dndEndMinutes;
    } else {
      // 穿越午夜，例如 23:00–07:00
      return currentMinutes >= dndStartMinutes || currentMinutes < dndEndMinutes;
    }
  }

  // 定时检查提醒
  checkTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
    try {
      try {
        // ignore: invalid_use_of_visible_for_testing_member, deprecated_member_use
        await prefs.reload();
      } catch (_) {
        // 某些平台不支持 reload，忽略即可
      }
      // 检查监测状态是否仍然开启
      final isMonitoring = prefs.getBool('monitoring') ?? false;
      if (!isMonitoring) {
        // 监测已关闭，停止服务
        accelSub?.cancel();
        checkTimer?.cancel();
        service.stopSelf();
        return;
      }
      
      if (!isSideLying || sideLyingSince == null) return;

      final now = DateTime.now();
      
      // 重新读取设置（可能用户修改了）
      final currentVibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      final currentThresholdSeconds = prefs.getInt('threshold_seconds') ?? 5;
      final dndStartMinutes = prefs.getInt('dnd_start_minutes') ?? 23 * 60;
      final dndEndMinutes = prefs.getInt('dnd_end_minutes') ?? 7 * 60;
      
      // 更新本地变量
      vibrationEnabled = currentVibrationEnabled;
      thresholdSeconds = currentThresholdSeconds;
      
      // 检查免打扰时段
      if (isInDnd(now, dndStartMinutes, dndEndMinutes)) return;

      final elapsed = now.difference(sideLyingSince!).inSeconds;
      if (elapsed < thresholdSeconds) return;

      // 重置计时起点
      sideLyingSince = now;

      // 震动提醒
      if (vibrationEnabled) {
        try {
          if ((await Vibration.hasVibrator()) ?? false) {
            Vibration.vibrate(pattern: [0, 120, 60, 120]);
          }
        } catch (e) {
          // 忽略震动错误
        }
      }

      // 发送通知
      const androidDetails = AndroidNotificationDetails(
        'posture_guardian_channel',
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
      const notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );
      await notifications.show(
        1,
        '姿势不对哦～',
        '你可能正在侧躺玩手机，注意颈椎健康哦～',
        notificationDetails,
      );
    } catch (e) {
      // 捕获所有错误，防止服务崩溃
      print('Background service error: $e');
    }
  });

  // 监听服务停止
  service.on('stopService').listen((event) {
    accelSub?.cancel();
    checkTimer?.cancel();
    service.stopSelf();
  });
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
      background: background,
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

  // 设置与状态
  bool _monitoring = false;
  bool _vibrationEnabled = true;
  int _thresholdSeconds = 5; // 默认从 5 秒开始更适合 MVP 体验
  TimeOfDay _dndStart = const TimeOfDay(hour: 23, minute: 0);
  TimeOfDay _dndEnd = const TimeOfDay(hour: 7, minute: 0);

  // 统计
  int _todayRemindCount = 0;
  DateTime _today = DateTime.now();

  // 传感器 & 姿态检测
  // 原始订阅
  StreamSubscription<AccelerometerEvent>? _accelSub;
  // 当前是否确认处于“稳定的侧躺状态”
  bool _isSideLying = false;
  // 最近一次确认“稳定侧躺”起始时间（用于健康提醒计时）
  DateTime? _sideLyingSince;
  // 候选侧躺开始时间（用于稳定期判断）
  DateTime? _sideCandidateSince;
  // 上一次重力模长（用于检测大幅姿势变化）
  double? _lastG;
  // 指数平滑后的重力方向（低通滤波）
  double _avgNx = 0;
  double _avgNy = 0;
  double _avgNz = 1;
  double _avgG = 9.8;
  Timer? _checkTimer;

  // 通知服务
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _isInBackground = false;
  // 提醒弹窗状态：是否正在显示
  bool _isReminderDialogShowing = false;
  
  // 悬浮窗相关（使用原生悬浮窗）
  bool _isFloatingWindowVisible = false;
  bool _hasOverlayPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsListener = _handleSettingsChanged;
    _initializeNotifications();
    _checkOverlayPermission();
    _initSettings();
  }
  
  /// 检查悬浮窗权限
  Future<void> _checkOverlayPermission() async {
    final hasPermission = await FloatingWindowManager.checkOverlayPermission();
    setState(() {
      _hasOverlayPermission = hasPermission;
    });
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

    // 请求通知权限（Android 13+）
    if (await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission() ??
        false) {
      // 权限已授予
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
      _today = _settingsRepo.today;
      _todayRemindCount = _settingsRepo.todayRemindCount;
    });
  }

  void _handleMonitoringPipeline(bool monitoringEnabled) {
    if (monitoringEnabled) {
      if (!_isInBackground && _accelSub == null) {
        _startSensorListening();
      }
      if (_isInBackground && !_isFloatingWindowVisible) {
        unawaited(_showFloatingWindow());
      }
    } else {
      if (_accelSub != null) {
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
    _accelSub?.cancel();
    _checkTimer?.cancel();
    _lastG = null;
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
      if (_monitoring && _accelSub == null) {
        _startSensorListening();
      }
      // 重新加载统计数据（可能原生服务更新了）
      _reloadSettingsFromDisk();
    }
  }
  
  /// 显示悬浮窗（使用原生悬浮窗）
  Future<void> _showFloatingWindow() async {
    if (_isFloatingWindowVisible || !_monitoring) return;
    
    // 检查权限
    if (!_hasOverlayPermission) {
      // 请求权限
      await FloatingWindowManager.requestOverlayPermission();
      // 重新检查权限
      await _checkOverlayPermission();
      if (!_hasOverlayPermission) {
        // 权限未授予，显示提示
        if (mounted) {
          _showPermissionDialog();
        }
        return;
      }
    }
    
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
  
  /// 显示权限请求对话框
  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF22232A),
        title: const Text(
          '需要悬浮窗权限',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '为了在后台持续监测，需要授予悬浮窗权限。请在设置中允许"在其他应用上层显示"。',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await FloatingWindowManager.requestOverlayPermission();
              await _checkOverlayPermission();
            },
            child: const Text(
              '去设置',
              style: TextStyle(color: Color(0xFF4361EE)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reloadSettingsFromDisk() async {
    if (!_settingsReady) return;
    await _settingsRepo.refreshFromDisk();
  }

  /// 通用轻微震动（尊重设置开关）
  void _vibrateOnce({int durationMs = 80}) {
    if (!_vibrationEnabled) return;
    Vibration.hasVibrator().then((hasVibrator) {
      if (hasVibrator == true) {
        Vibration.vibrate(duration: durationMs);
      }
    });
  }

  void _toggleMonitoring() {
    final next = !_monitoring;
    setState(() {
      _monitoring = next;
    });
    if (next) {
      _vibrateOnce(durationMs: 60);
    }
    _handleMonitoringPipeline(next);
    unawaited(_settingsRepo.setMonitoring(next));
  }
  
  void _startSensorListening() {
    _accelSub?.cancel();
    _checkTimer?.cancel();
    _sideCandidateSince = null;
    _lastG = null;

    _accelSub = accelerometerEvents.listen((event) {
      // 使用重力方向 + 低通滤波 + 稳定期进行更精细、宽松的姿态判断
      final ax = event.x;
      final ay = event.y;
      final az = event.z;
      final g = sqrt(ax * ax + ay * ay + az * az);

      if (g < 1e-3) {
        // 数据异常，直接忽略
        return;
      }

      // 归一化重力分量（-1 ~ 1），只关心方向
      final nx = ax / g;
      final ny = ay / g;
      final nz = az / g;

      // 指数平滑（低通滤波），减弱短暂抖动的影响
      const alpha = 0.15; // 越小越平滑
      _avgNx = alpha * nx + (1 - alpha) * _avgNx;
      _avgNy = alpha * ny + (1 - alpha) * _avgNy;
      _avgNz = alpha * nz + (1 - alpha) * _avgNz;
      _avgG = alpha * g + (1 - alpha) * _avgG;

      // 通过 g 的变化幅度检测较大姿势变换（例如突然翻身、起身）
      double deltaG = 0;
      if (_lastG != null) {
        deltaG = (g - _lastG!).abs();
      }
      _lastG = g;

      // 如果发生较大的姿势变化，则重置候选与确认状态，重新进入判定流程
      if (deltaG > 0.8) {
        _sideCandidateSince = null;
        if (_isSideLying) {
          setState(() {
            _isSideLying = false;
            _sideLyingSince = null;
          });
          _updateFloatingWindowState();
        }
      }

      // 判定 1：基于“平滑后的”重力方向（更抽象，适配更多设备）
      //  - z 分量不占主导：说明不是平放在桌面 / 天花板上
      //  - x 或 y 分量占主导：说明手机被明显“侧着”拿着
      final bool isScreenRoughlyVertical = _avgNz.abs() < 0.8;
      final bool isGravityMostlySide =
          _avgNx.abs() > 0.4 || _avgNy.abs() > 0.4; // 左右或前后方向占主导
      final bool isSideByDirection =
          isScreenRoughlyVertical && isGravityMostlySide;

      // 判定 2：基于原始加速度值的宽松判断（与最初的逻辑兼容，提供冗余保障）
      final bool isSideByRaw = ax.abs() > 6.5 && az.abs() < 5.0;

      final isSide = isSideByDirection || isSideByRaw;

      final now = DateTime.now();

      if (isSide) {
        // 第一次进入候选“侧躺区间”
        _sideCandidateSince ??= now;

        final stableDuration =
            now.difference(_sideCandidateSince!).inSeconds;

        // 需要先经过一个"稳定期"（例如 2 秒），再真正确认进入侧躺
        const stableThresholdSeconds = 2;
        if (!_isSideLying && stableDuration >= stableThresholdSeconds) {
          setState(() {
            _isSideLying = true;
            // 确认进入侧躺的时间点，用于后续健康提醒计时（再叠加 _thresholdSeconds）
            _sideLyingSince = now;
          });
          // 第一次进入"稳定的侧躺状态"时，给一次轻微震动反馈
          _vibrateOnce(durationMs: 50);
          // 更新悬浮窗状态
          _updateFloatingWindowState();
        }
      } else {
        // 退出候选与确认状态
        if (_isSideLying) {
          setState(() {
            _sideCandidateSince = null;
            _isSideLying = false;
            _sideLyingSince = null;
          });
          // 更新悬浮窗状态
          _updateFloatingWindowState();
        } else {
          _sideCandidateSince = null;
        }
      }
    });

    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _maybeTriggerReminder();
    });
  }

  void _stopSensorListening() {
    _accelSub?.cancel();
    _accelSub = null;
    _checkTimer?.cancel();
    _checkTimer = null;
    _isSideLying = false;
    _sideLyingSince = null;
    _isReminderDialogShowing = false;
  }

  bool _isInDnd(DateTime now) {
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
      if (_vibrationEnabled &&
          ((await Vibration.hasVibrator()) ?? false)) {
        Vibration.vibrate(pattern: [0, 120, 60, 120]);
      }
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
    if (_vibrationEnabled &&
        ((await Vibration.hasVibrator()) ?? false)) {
      Vibration.vibrate(pattern: [0, 120, 60, 120]);
    }

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
    const androidDetails = AndroidNotificationDetails(
      'posture_guardian_channel',
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

    const notificationDetails = NotificationDetails(
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
      pageBuilder: (context, _, __) {
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
                  color: Colors.black.withOpacity(0.4),
                ),
              ),
            ),
            Center(
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
                  child: _ReminderCard(
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
        onVibrationChanged: _updateVibration,
        onThresholdChanged: _updateThreshold,
        onDndStartChanged: _updateDndStart,
        onDndEndChanged: _updateDndEnd,
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

/// 首页：核心监测控制 + 今日提醒次数
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.monitoring,
    required this.isSideLying,
    required this.remindCount,
    required this.thresholdSeconds,
    required this.onToggleMonitoring,
  });

  final bool monitoring;
  final bool isSideLying;
  final int remindCount;
  final int thresholdSeconds;
  final VoidCallback onToggleMonitoring;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const primary = Color(0xFF4361EE);
    const haloColor = Color(0xFF6BAA75); // 鼠尾草绿

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent, // 透明状态栏
        statusBarIconBrightness: Brightness.light, // 浅色图标（白色）
        statusBarBrightness: Brightness.dark, // iOS 状态栏样式
        systemNavigationBarColor: Color(0xFF1B1B1E), // 导航栏颜色
        systemNavigationBarIconBrightness: Brightness.light, // 导航栏图标颜色
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1B1B1E), Color(0xFF121218)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const SizedBox(height: 16),
              // 顶部标题居中
              Text(
                '枕边哨',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  fontSize: 24,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),

              // 中间大按钮区域
              Expanded(
                child: Center(
                  child: _BreathingButton(
                    active: monitoring,
                    onTap: onToggleMonitoring,
                    primary: primary,
                    haloColor: haloColor,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 今日提醒次数卡片 - 美化样式
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: primary.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.notifications_active_rounded,
                                color: primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '今日提醒次数',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$remindCount 次',
                                  style: theme.textTheme.headlineMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 28,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '触发条件',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '≥ $thresholdSeconds 秒',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 持续侧躺状态实时提示（只要保持侧躺就一直显示）- 美化样式
              if (monitoring && isSideLying)
                _GlassCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFB5179E).withOpacity(0.3),
                              const Color(0xFFB5179E).withOpacity(0.1),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.bedtime_rounded,
                          color: Color(0xFFB5179E),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '正在检测侧躺姿势',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFB5179E),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '保持当前姿势时，此提示会一直显示，超过设定时长将弹出健康提醒。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 设置页：震动开关、时间阈值、免打扰时段
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.vibrationEnabled,
    required this.thresholdSeconds,
    required this.dndStart,
    required this.dndEnd,
    required this.onVibrationChanged,
    required this.onThresholdChanged,
    required this.onDndStartChanged,
    required this.onDndEndChanged,
  });

  final bool vibrationEnabled;
  final int thresholdSeconds;
  final TimeOfDay dndStart;
  final TimeOfDay dndEnd;
  final ValueChanged<bool> onVibrationChanged;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<TimeOfDay> onDndStartChanged;
  final ValueChanged<TimeOfDay> onDndEndChanged;

  String _formatTime(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1B1B1E), Color(0xFF121218)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                '设置',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '根据你的习惯，调节提醒的方式',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 24),

              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '震动提醒',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '轻柔震动，像朋友轻拍你的肩膀',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: vibrationEnabled,
                          onChanged: onVibrationChanged,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '侧躺持续时间阈值',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '仅当侧躺持续达到该时长才提醒，避免误判',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${thresholdSeconds.toString()} 秒',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '5 - 120 秒',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      min: 5,
                      max: 120,
                      divisions: 23,
                      value: thresholdSeconds.toDouble().clamp(5, 120),
                      onChanged: onThresholdChanged,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '免打扰时段',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '在该时间段内，不会弹出提醒或震动',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _DndTimeChip(
                          label: '开始',
                          timeText: _formatTime(dndStart),
                          onTap: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: dndStart,
                            );
                            if (picked != null) {
                              onDndStartChanged(picked);
                            }
                          },
                        ),
                        const SizedBox(width: 12),
                        _DndTimeChip(
                          label: '结束',
                          timeText: _formatTime(dndEnd),
                          onTap: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: dndEnd,
                            );
                            if (picked != null) {
                              onDndEndChanged(picked);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '隐私与数据说明',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '本 App 仅使用设备传感器判断姿态，不采集、不上传任何个人隐私数据。'
                      '所有设置与统计仅保存在本机，可随时卸载清除。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// 中央呼吸按钮，带轻微缩放与光晕效果
class _BreathingButton extends StatefulWidget {
  const _BreathingButton({
    required this.active,
    required this.onTap,
    required this.primary,
    required this.haloColor,
  });

  final bool active;
  final VoidCallback onTap;
  final Color primary;
  final Color haloColor;

  @override
  State<_BreathingButton> createState() => _BreathingButtonState();
}

class _BreathingButtonState extends State<_BreathingButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
      lowerBound: 0.95,
      upperBound: 1.05,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.active;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = isActive ? _controller.value : 1.0;
        return GestureDetector(
          onTap: widget.onTap,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: isActive
                      ? [widget.haloColor.withOpacity(0.35), Colors.transparent]
                      : [Colors.transparent, Colors.transparent],
                  radius: 0.9,
                ),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: isActive
                          ? [widget.haloColor, widget.haloColor.withOpacity(0.9)]
                          : [Colors.white.withOpacity(0.12), Colors.white10],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      if (isActive)
                        BoxShadow(
                          color: widget.haloColor.withOpacity(0.55),
                          blurRadius: 35,
                          spreadRadius: 6,
                        ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.7),
                        blurRadius: 24,
                        offset: const Offset(0, 18),
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withOpacity(0.22),
                      width: 1.5,
                    ),
                  ),
        child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
          children: [
                      Icon(
                        isActive ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 46,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isActive ? '监测中' : '开始监测',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
            Text(
                        isActive ? '保持舒服的坐姿就好' : '轻点一下，守护你的眼睛',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 玻璃拟态卡片组件
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(0.08),
                Colors.white.withOpacity(0.02),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Colors.white.withOpacity(0.16),
              width: 1,
            ),
          ),
          child: child,
        ),
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
class _DndTimeChip extends StatelessWidget {
  const _DndTimeChip({
    required this.label,
    required this.timeText,
    required this.onTap,
  });

  final String label;
  final String timeText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Colors.white.withOpacity(0.06),
            border: Border.all(
              color: Colors.white.withOpacity(0.18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    timeText,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 提醒弹窗内容卡片
class _ReminderCard extends StatelessWidget {
  const _ReminderCard({required this.onClose});

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
                Colors.white.withOpacity(0.9),
                Colors.white.withOpacity(0.85),
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
                  color: Color(0xFF333333),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '你可能正侧躺玩手机，试着稍微调整一下姿势，给颈椎一点温柔。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Color(0xFF555555),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '可在设置中调整提醒时间和免打扰时段。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Color(0xFF888888),
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

// 注意：旧的Flutter Overlay悬浮窗组件已移除，现在使用原生Android悬浮窗
// 原生悬浮窗可以在其他应用上显示，提供更好的后台监测体验


