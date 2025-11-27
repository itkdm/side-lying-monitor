import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一管理 SharedPreferences，避免高频重复读取并提供内存缓存
class SettingsRepository extends ChangeNotifier {
  SettingsRepository._internal();
  static final SettingsRepository instance = SettingsRepository._internal();
  static const MethodChannel _channel =
      MethodChannel('com.example.flutter_application_1/floating_window');

  SharedPreferences? _prefs;
  bool _initialized = false;

  bool _monitoring = false;
  bool _vibrationEnabled = true;
  int _thresholdSeconds = 5;
  int _dndStartMinutes = 23 * 60;
  int _dndEndMinutes = 7 * 60;
  bool _dndEnabled = false;
  DateTime _today = _normalizeDate(DateTime.now());
  int _todayRemindCount = 0;

  bool get monitoring => _monitoring;
  bool get vibrationEnabled => _vibrationEnabled;
  int get thresholdSeconds => _thresholdSeconds;
  int get dndStartMinutes => _dndStartMinutes;
  int get dndEndMinutes => _dndEndMinutes;
  bool get dndEnabled => _dndEnabled;
  DateTime get today => _today;
  int get todayRemindCount => _todayRemindCount;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    await _loadFromPrefs();
    _initialized = true;
    _scheduleNativeSync();
  }

  Future<void> refreshFromDisk() async {
    await _ensureReady();
    try {
      // ignore: invalid_use_of_visible_for_testing_member, deprecated_member_use
      await _prefs!.reload();
    } catch (_) {
      // 某些平台不支持 reload，可忽略
    }
    await _loadFromPrefs();
    notifyListeners();
  }

  Future<void> setMonitoring(bool value) async {
    await _ensureReady();
    if (_monitoring == value) return;
    _monitoring = value;
    await _prefs!.setBool('monitoring', value);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> setVibrationEnabled(bool value) async {
    await _ensureReady();
    if (_vibrationEnabled == value) return;
    _vibrationEnabled = value;
    await _prefs!.setBool('vibration_enabled', value);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> setThresholdSeconds(int value) async {
    await _ensureReady();
    final int newValue = value.clamp(5, 120).toInt();
    if (_thresholdSeconds == newValue) return;
    _thresholdSeconds = newValue;
    await _prefs!.setInt('threshold_seconds', _thresholdSeconds);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> setDndStartMinutes(int minutes) async {
    await _ensureReady();
    if (_dndStartMinutes == minutes) return;
    _dndStartMinutes = minutes;
    await _prefs!.setInt('dnd_start_minutes', minutes);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> setDndEndMinutes(int minutes) async {
    await _ensureReady();
    if (_dndEndMinutes == minutes) return;
    _dndEndMinutes = minutes;
    await _prefs!.setInt('dnd_end_minutes', minutes);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> setDndEnabled(bool value) async {
    await _ensureReady();
    if (_dndEnabled == value) return;
    _dndEnabled = value;
    await _prefs!.setBool('dnd_enabled', value);
    notifyListeners();
    _scheduleNativeSync();
  }

  Future<void> resetTodayIfNeeded(DateTime now) async {
    await _ensureReady();
    final normalized = _normalizeDate(now);
    if (_today.isAtSameMomentAs(normalized)) return;
    await _resetTodayStats(normalized);
    notifyListeners();
  }

  Future<void> incrementTodayRemindCount({DateTime? at}) async {
    await _ensureReady();
    final timestamp = at ?? DateTime.now();
    final normalized = _normalizeDate(timestamp);
    if (!_today.isAtSameMomentAs(normalized)) {
      await _resetTodayStats(normalized);
    }
    _todayRemindCount += 1;
    await _persistTodayStats();
    notifyListeners();
  }

  static DateTime _normalizeDate(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  Future<void> _ensureReady() async {
    if (!_initialized) {
      await init();
    }
  }

  Future<void> _loadFromPrefs() async {
    _monitoring = _prefs!.getBool('monitoring') ?? false;
    _vibrationEnabled = _prefs!.getBool('vibration_enabled') ?? true;
    _thresholdSeconds = _prefs!.getInt('threshold_seconds') ?? 5;
    _dndStartMinutes = _prefs!.getInt('dnd_start_minutes') ?? 23 * 60;
    _dndEndMinutes = _prefs!.getInt('dnd_end_minutes') ?? 7 * 60;
    _dndEnabled = _prefs!.getBool('dnd_enabled') ?? false;

    final now = DateTime.now();
    final todayKey = _formatDate(now);
    final storedDate = _prefs!.getString('today_date');
    final storedCount = _prefs!.getInt('today_remind_count') ?? 0;
    _today = _normalizeDate(now);

    if (storedDate == todayKey) {
      _todayRemindCount = storedCount;
    } else {
      _todayRemindCount = 0;
      await _prefs!.setString('today_date', todayKey);
      await _prefs!.setInt('today_remind_count', 0);
    }
  }

  Future<void> _resetTodayStats(DateTime normalized) async {
    _today = normalized;
    _todayRemindCount = 0;
    await _persistTodayStats();
  }

  Future<void> _persistTodayStats() async {
    final todayKey = _formatDate(_today);
    await _prefs!.setString('today_date', todayKey);
    await _prefs!.setInt('today_remind_count', _todayRemindCount);
  }

  String _formatDate(DateTime value) {
    return '${value.year}-${value.month}-${value.day}';
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _prefs = null;
    _initialized = false;
    _monitoring = false;
    _vibrationEnabled = true;
    _thresholdSeconds = 5;
    _dndStartMinutes = 23 * 60;
    _dndEndMinutes = 7 * 60;
    _dndEnabled = false;
    _today = _normalizeDate(DateTime.now());
    _todayRemindCount = 0;
  }

  Future<void> broadcastSettings() async {
    await _ensureReady();
    await _sendSettingsToNative();
  }

  void _scheduleNativeSync() {
    if (!_initialized) return;
    unawaited(_sendSettingsToNative());
  }

  Future<void> _sendSettingsToNative() async {
    final payload = {
      'monitoring': _monitoring,
      'vibrationEnabled': _vibrationEnabled,
      'thresholdSeconds': _thresholdSeconds,
      'dndStartMinutes': _dndStartMinutes,
      'dndEndMinutes': _dndEndMinutes,
      'dndEnabled': _dndEnabled,
    };
    try {
      await _channel.invokeMethod('syncSettings', payload);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to sync settings to native layer: $e');
      }
    }
  }
}

