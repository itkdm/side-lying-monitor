import 'package:flutter/material.dart';

import 'floating_window_manager.dart';

/// 把悬浮窗权限检查与引导封装成可观察的服务，降低 UI 复杂度。
class PermissionCoordinator extends ChangeNotifier {
  bool _overlayGranted = false;

  bool get hasOverlayPermission => _overlayGranted;

  Future<void> init() async {
    await refreshOverlayPermission();
  }

  Future<void> refreshOverlayPermission() async {
    final granted = await FloatingWindowManager.checkOverlayPermission();
    if (granted != _overlayGranted) {
      _overlayGranted = granted;
      notifyListeners();
    }
  }

  Future<bool> ensureOverlayPermission(BuildContext context) async {
    if (_overlayGranted) return true;
    await FloatingWindowManager.requestOverlayPermission();
    await refreshOverlayPermission();
    if (_overlayGranted) {
      return true;
    }
    if (context.mounted) {
      await _showPermissionDialog(context);
    }
    return _overlayGranted;
  }

  Future<void> _showPermissionDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF22232A),
        title: const Text(
          '需要悬浮窗权限',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '为了在后台持续监测，需要授予悬浮窗权限。请在设置中允许“在其他应用上层显示”。',
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
              await refreshOverlayPermission();
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
}

