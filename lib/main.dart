import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

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
      background: background,
      surface: const Color(0xFF22232A),
    );

    return MaterialApp(
      title: '侧躺玩手机提醒',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: background,
        fontFamily: 'Roboto',
      ),
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

class _RootShellState extends State<RootShell> {
  // UI & 导航
  int _currentIndex = 0;

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

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _checkTimer?.cancel();
    _lastG = null;
    super.dispose();
  }

  Future<void> _loadPersistedState() async {
    final prefs = await SharedPreferences.getInstance();

    final now = DateTime.now();
    final todayKey = '${now.year}-${now.month}-${now.day}';
    final storedDate = prefs.getString('today_date');
    final storedCount =
        storedDate == todayKey ? prefs.getInt('today_remind_count') ?? 0 : 0;

    setState(() {
      _vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      _thresholdSeconds = prefs.getInt('threshold_seconds') ?? 5;

      final startMinutes = prefs.getInt('dnd_start_minutes') ?? 23 * 60;
      final endMinutes = prefs.getInt('dnd_end_minutes') ?? 7 * 60;
      _dndStart = TimeOfDay(hour: startMinutes ~/ 60, minute: startMinutes % 60);
      _dndEnd = TimeOfDay(hour: endMinutes ~/ 60, minute: endMinutes % 60);

      _today = now;
      _todayRemindCount = storedCount;
    });
  }

  Future<void> _persistSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('vibration_enabled', _vibrationEnabled);
    await prefs.setInt('threshold_seconds', _thresholdSeconds);
    await prefs.setInt('dnd_start_minutes', _dndStart.hour * 60 + _dndStart.minute);
    await prefs.setInt('dnd_end_minutes', _dndEnd.hour * 60 + _dndEnd.minute);
  }

  Future<void> _persistTodayStats() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = '${_today.year}-${_today.month}-${_today.day}';
    await prefs.setString('today_date', todayKey);
    await prefs.setInt('today_remind_count', _todayRemindCount);
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
    setState(() {
      _monitoring = !_monitoring;
    });

    if (_monitoring) {
      // 开始监测时给一个轻微提示震动
      _vibrateOnce(durationMs: 60);
      _startSensorListening();
    } else {
      _stopSensorListening();
    }
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
          _isSideLying = false;
          _sideLyingSince = null;
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

        // 需要先经过一个“稳定期”（例如 2 秒），再真正确认进入侧躺
        const stableThresholdSeconds = 2;
        if (!_isSideLying && stableDuration >= stableThresholdSeconds) {
          _isSideLying = true;
          // 确认进入侧躺的时间点，用于后续健康提醒计时（再叠加 _thresholdSeconds）
          _sideLyingSince = now;
          // 第一次进入“稳定的侧躺状态”时，给一次轻微震动反馈
          _vibrateOnce(durationMs: 50);
          _showSideStartDialog();
        }
      } else {
        // 退出候选与确认状态
        _sideCandidateSince = null;
        _isSideLying = false;
        _sideLyingSince = null;
      }
    });

    _checkTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _maybeTriggerReminder();
    });
  }

  void _stopSensorListening() {
    _accelSub?.cancel();
    _checkTimer?.cancel();
    _isSideLying = false;
    _sideLyingSince = null;
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
      await _persistTodayStats();
    }

    if (_isInDnd(now)) return;

    final elapsed = now.difference(_sideLyingSince!).inSeconds;
    if (elapsed < _thresholdSeconds) return;

    // 避免多次触发：重置起点，下一次需重新满足阈值
    _sideLyingSince = now;

    if (!mounted) return;

    setState(() {
      _todayRemindCount += 1;
    });
    await _persistTodayStats();

    // 震动（如果可用且开启）
    if (_vibrationEnabled &&
        ((await Vibration.hasVibrator()) ?? false)) {
      Vibration.vibrate(pattern: [0, 120, 60, 120]);
    }

    _showReminderDialog();
  }

  void _showReminderDialog() {
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
                    onClose: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 检测到“进入侧躺状态”时的轻量提示弹窗（短暂出现 1.5 秒）
  void _showSideStartDialog() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '侧躺检测开始',
      pageBuilder: (context, _, __) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (context, animation, secondary, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: FadeTransition(
                  opacity: curved,
                  child: ScaleTransition(
                    scale:
                        Tween<double>(begin: 0.96, end: 1.0).animate(curved),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 24,
                        right: 24,
                        bottom: 24,
                      ),
                      child: _GlassCard(
                        child: Row(
                          children: [
                            const Icon(
                              Icons.bedtime_rounded,
                              color: Color(0xFFB5179E),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Text(
                                    '检测到你正在侧躺',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '已开始计时，超过设定时长会提醒你调整姿势。',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    // 1.5 秒后自动关闭这个轻提示
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }

  // —— 设置项的更新回调 ——

  void _updateVibration(bool value) {
    setState(() {
      _vibrationEnabled = value;
    });
    _persistSettings();
  }

  void _updateThreshold(double value) {
    setState(() {
      _thresholdSeconds = value.round();
    });
    _persistSettings();
  }

  void _updateDndStart(TimeOfDay value) {
    setState(() {
      _dndStart = value;
    });
    _persistSettings();
  }

  void _updateDndEnd(TimeOfDay value) {
    setState(() {
      _dndEnd = value;
    });
    _persistSettings();
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

    return Container(
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                '侧躺监测',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                monitoring ? 'App 正在默默守护你的颈椎' : '今天的你也坐姿端正吗？',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 32),

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

              // 今日提醒次数卡片
              _GlassCard(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '今日提醒次数',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$remindCount 次',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '触发条件',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '侧躺 ≥ $thresholdSeconds 秒',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 持续侧躺状态实时提示（只要保持侧躺就一直显示）
              if (monitoring && isSideLying)
                _GlassCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.bedtime_rounded,
                        color: Color(0xFFB5179E),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '正在检测侧躺姿势',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '保持当前姿势时，此提示会一直显示，超过设定时长将弹出健康提醒。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
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
                '根据你的习惯，调节提醒的方式与灵敏度',
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
                        isActive ? '保持舒服的坐姿就好' : '轻点一下，守护你的颈椎',
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
                '可在设置中调整提醒灵敏度和免打扰时段。',
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


