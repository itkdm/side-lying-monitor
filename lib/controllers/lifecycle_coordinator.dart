import 'package:flutter/material.dart';
import 'package:flutter_application_1/services/floating_window_manager.dart';
import 'package:flutter_application_1/services/settings_repository.dart';

/// 生命周期协调器：负责管理应用前后台切换时的监测逻辑
/// 注意：现在统一使用原生服务进行检测，Flutter层仅负责UI展示
class LifecycleCoordinator {
  LifecycleCoordinator({
    required SettingsRepository settingsRepository,
    required VoidCallback onForegroundResumed,
  })  : _settingsRepository = settingsRepository,
        _onForegroundResumed = onForegroundResumed;

  final SettingsRepository _settingsRepository;
  final VoidCallback _onForegroundResumed;

  bool _isInBackground = false;
  bool _isFloatingWindowVisible = false;

  bool get isInBackground => _isInBackground;
  bool get isFloatingWindowVisible => _isFloatingWindowVisible;

  /// 处理应用生命周期变化
  void handleLifecycleChange(
    AppLifecycleState state,
    bool monitoring,
    bool isSideLying,
  ) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // 进入后台：如果监测开启，显示悬浮窗（原生服务会继续监测）
      _isInBackground = true;
      if (monitoring && !_isFloatingWindowVisible) {
        // 显示悬浮窗（原生服务已经在监测）
        _showFloatingWindow(isSideLying);
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台：隐藏悬浮窗（原生服务继续监测，通过EventChannel推送状态）
      _isInBackground = false;
      // 强制隐藏悬浮窗
      if (_isFloatingWindowVisible) {
        _hideFloatingWindow();
      }
      // 重新加载统计数据（可能原生服务更新了）
      _reloadSettingsFromDisk();
      _onForegroundResumed();
    }
  }

  /// 显示悬浮窗（需要权限检查，由外部调用 ensureOverlayPermission）
  Future<void> showFloatingWindow(bool isSideLying) async {
    if (_isFloatingWindowVisible) return;

    final success = await FloatingWindowManager.showFloatingWindow();
    if (success) {
      _isFloatingWindowVisible = true;
      // 更新初始状态
      FloatingWindowManager.updateFloatingWindowState(isSideLying);
    }
  }

  /// 内部显示悬浮窗（不检查权限，用于生命周期切换）
  Future<void> _showFloatingWindow(bool isSideLying) async {
    await showFloatingWindow(isSideLying);
  }

  /// 隐藏悬浮窗
  Future<void> _hideFloatingWindow() async {
    if (!_isFloatingWindowVisible) return;
    await FloatingWindowManager.hideFloatingWindow();
    _isFloatingWindowVisible = false;
  }

  /// 更新悬浮窗状态
  void updateFloatingWindowState(bool isSideLying) {
    if (_isFloatingWindowVisible) {
      FloatingWindowManager.updateFloatingWindowState(isSideLying);
    }
  }

  /// 重新加载设置
  Future<void> _reloadSettingsFromDisk() async {
    await _settingsRepository.refreshFromDisk();
  }

  /// 清理资源
  void dispose() {
    if (_isFloatingWindowVisible) {
      FloatingWindowManager.hideFloatingWindow();
    }
  }
}

