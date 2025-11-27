# 悬浮窗消失问题修复说明

## 问题描述

当悬浮窗从正常监测状态切换到识别到侧躺状态时，悬浮窗立即消失，且没有震动提醒，应用内的提醒次数也没有增加。

## 问题分析

### 根本原因

1. **UI更新异常**：在更新悬浮窗状态时，可能因为资源获取失败或UI操作异常导致悬浮窗被移除
2. **线程安全问题**：虽然已经切换到主线程，但可能在某些情况下仍然出现问题
3. **悬浮窗丢失检测不足**：没有检测悬浮窗是否真的在WindowManager中
4. **SharedPreferences key格式**：可能读取设置时key格式不正确

## 解决方案

### 1. 增强悬浮窗丢失检测和自动恢复

```kotlin
private fun showFloatingWindow() {
    // 如果悬浮窗已存在，先检查是否真的在WindowManager中
    if (floatingView != null) {
        try {
            windowManager?.updateViewLayout(floatingView, windowParams)
            // 如果更新成功，说明悬浮窗还在
            return
        } catch (e: Exception) {
            // 如果更新失败，说明悬浮窗已丢失，需要重新创建
            floatingView = null
            windowParams = null
        }
    }
    // 重新创建悬浮窗
}
```

### 2. 增强UI更新异常处理

```kotlin
private fun updateFloatingWindowState(sideLying: Boolean) {
    // 检查悬浮窗是否存在
    if (floatingView == null) {
        // 如果悬浮窗丢失，尝试重新创建
        if (isMonitoring) {
            showFloatingWindow()
        }
        return
    }
    
    // 检查UI组件是否存在
    if (floatingButton == null || floatingText == null) {
        // 如果UI组件丢失，重新创建悬浮窗
        hideFloatingWindow()
        if (isMonitoring) {
            showFloatingWindow()
        }
        return
    }
    
    // 更新UI时捕获异常
    try {
        // UI更新操作
    } catch (e: Exception) {
        // 如果UI更新失败，尝试重新创建悬浮窗
        if (isMonitoring) {
            hideFloatingWindow()
            Handler(Looper.getMainLooper()).postDelayed({
                if (isMonitoring) {
                    showFloatingWindow()
                }
            }, 100)
        }
    }
}
```

### 3. 修复SharedPreferences key格式

```kotlin
// 尝试两种key格式
val vibrationEnabled = if (prefs.contains("flutter.vibration_enabled")) {
    prefs.getBoolean("flutter.vibration_enabled", true)
} else {
    prefs.getBoolean("vibration_enabled", true)
}
```

### 4. 添加详细日志

- 在关键操作处添加日志，方便调试
- 记录状态变化、UI更新、提醒触发等关键事件

### 5. 在检测到侧躺时确保悬浮窗存在

```kotlin
if (!isSideLying && stableDuration >= stableThresholdSeconds) {
    isSideLying = true
    sideLyingSince = now
    Handler(Looper.getMainLooper()).post {
        // 确保悬浮窗存在
        if (floatingView == null && isMonitoring) {
            showFloatingWindow()
        }
        updateFloatingWindowState(true)
    }
}
```

## 测试建议

1. **状态切换测试**：多次切换正常/侧躺状态，确认悬浮窗不会消失
2. **长时间运行测试**：让服务长时间运行，确认悬浮窗持续显示
3. **异常场景测试**：模拟各种异常情况，确认服务不会崩溃
4. **日志检查**：查看logcat日志，确认是否有异常信息

## 调试方法

使用以下命令查看日志：
```bash
adb logcat | grep FloatingWindow
```

关键日志标签：
- `FloatingWindow`: 所有悬浮窗相关操作
- 查看是否有异常堆栈信息
- 查看状态更新是否成功

