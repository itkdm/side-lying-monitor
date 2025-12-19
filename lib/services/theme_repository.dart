import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_application_1/utils/logger.dart';

/// 主题模式枚举
enum AppThemeMode {
  dark, // 深色主题（默认，保留现有风格）
  light, // 亮色主题（新增）
}

/// 主题管理服务：管理应用主题状态和持久化
class ThemeRepository extends ChangeNotifier {
  ThemeRepository._internal();
  static final ThemeRepository instance = ThemeRepository._internal();

  SharedPreferences? _prefs;
  bool _initialized = false;
  AppThemeMode _themeMode = AppThemeMode.dark;

  AppThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == AppThemeMode.dark;
  bool get isLight => _themeMode == AppThemeMode.light;

  Future<void> init() async {
    if (_initialized) return;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _loadFromPrefs();
      _initialized = true;
      AppLogger.d('ThemeRepository', 'Theme initialized: $_themeMode');
    } catch (e, stackTrace) {
      AppLogger.e('ThemeRepository', 'Failed to init theme', e, stackTrace);
      _themeMode = AppThemeMode.dark; // 默认深色
      _initialized = true;
    }
  }

  Future<void> _ensureReady() async {
    if (!_initialized) {
      await init();
    }
  }

  Future<void> _loadFromPrefs() async {
    try {
      // 如果 _prefs 还未初始化，这里兜底获取一次，但不再递归调用 init()
      _prefs ??= await SharedPreferences.getInstance();
      final saved = _prefs?.getString('app_theme_mode');
      if (saved != null) {
        _themeMode = AppThemeMode.values.firstWhere(
          (e) => e.toString() == saved,
          orElse: () => AppThemeMode.dark,
        );
      }
    } catch (e, stackTrace) {
      AppLogger.e('ThemeRepository', 'Failed to load theme', e, stackTrace);
      _themeMode = AppThemeMode.dark;
    }
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    if (_themeMode == mode) return;
    await _ensureReady();
    try {
      _themeMode = mode;
      await _prefs?.setString('app_theme_mode', mode.toString());
      notifyListeners();
      AppLogger.d('ThemeRepository', 'Theme changed to: $mode');
    } catch (e, stackTrace) {
      AppLogger.e('ThemeRepository', 'Failed to save theme', e, stackTrace);
    }
  }

  Future<void> toggleTheme() async {
    final newMode = _themeMode == AppThemeMode.dark
        ? AppThemeMode.light
        : AppThemeMode.dark;
    await setThemeMode(newMode);
  }
}

