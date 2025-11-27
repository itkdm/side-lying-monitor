# 枕边哨代码巡检（2025-11-27）

## 架构概览

- **Flutter UI Shell（`lib/main.dart`）**：`PostureGuardianApp` 负责全局主题，`RootShell` 统一持有监测状态、提醒统计与生命周期钩子，并在前后台之间切换 Flutter 传感器监听与原生悬浮窗服务。
- **功能页面（`lib/pages/`）**：`HomePage` 与 `SettingsPage` 通过构造参数消费上层状态，以玻璃拟态组件 `GlassCard` 呈现交互。
- **服务层（`lib/services/`）**：`SettingsRepository` 统一访问 `SharedPreferences` 并通过 `MethodChannel` 同步到原生；`PostureMonitor` 将 `sensors_plus` 的加速度流转换为姿态状态；`PermissionCoordinator` 封装悬浮窗权限流程；`FloatingWindowManager` 将 Flutter 调用桥接到 Android。
- **Android 前台服务（`android/app/src/main/kotlin/...`）**：`FloatingWindowService` 在后台持久监听传感器并驱动系统悬浮窗、震动与本地通知；`MainActivity` 侧负责 MethodChannel 下发指令与设置广播。

以下问题互相独立，可单独修复并验证。

---

## 1. Android 13+ 通知渠道缺失导致后台提醒失效

```128:151:lib/main.dart
Future<void> _initializeNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  ...
  await _notifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (details) {
      // 用户点击通知时的处理
    },
  );
  ...
}
```

```438:464:lib/main.dart
const androidDetails = AndroidNotificationDetails(
  'posture_guardian_channel',
  '侧躺监测提醒',
  channelDescription: '当你侧躺玩手机时，会收到健康提醒',
  importance: Importance.high,
  priority: Priority.high,
  showWhen: true,
);
...
await _notifications.show(
  1,
  '姿势不对哦～',
  '你可能正在侧躺玩手机，注意颈椎健康哦～',
  notificationDetails,
);
```

- **现象/影响**：在 Android 8.0+（尤其是 13+）中，通知必须隶属已注册的渠道；当前初始化流程仅调用 `initialize`，却直接使用自定义渠道 ID `posture_guardian_channel` 发送通知。实机上会抛出 `PlatformException(Channel ... does not exist)` 并导致后台提醒完全丢失。
- **修改建议**：在 `_initializeNotifications()` 中通过 `resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(...)` 先注册渠道（可重用 Service 的文案），并确保只创建一次。必要时将渠道 ID 抽成常量避免前后不一致。
- **验证方式**：运行到 Android 13+，开启监测→退到后台→保持侧躺至阈值，应看到本地通知且无异常日志；重复运行 `flutter test` 及 `flutter analyze`，确认无新增告警。

---

## 2. `PostureState.copyWith` 丢失时间戳，导致未来扩展无法复用时间

```6:24:lib/services/posture_monitor.dart
class PostureState {
  const PostureState({
    required this.isSideLying,
    this.sideLyingSince,
  });
  ...
  PostureState copyWith({
    bool? isSideLying,
    DateTime? sideLyingSince,
  }) {
    return PostureState(
      isSideLying: isSideLying ?? this.isSideLying,
      sideLyingSince: sideLyingSince,
    );
  }
}
```

- **现象/影响**：`copyWith` 没有回退到已有的 `sideLyingSince`，任何只想更新 `isSideLying` 的调用都会把时间戳抹成 `null`。目前虽然未调用 `copyWith`，但一旦在 UI 或原生服务里使用这一 helper，就会立即丢失稳定检测的起点，直接影响提醒倒计时。
- **修改建议**：让 `sideLyingSince` 同样使用 `?? this.sideLyingSince`，并在 `test/` 下补一条覆盖案例，防止回归。
- **验证方式**：新增单元测试验证 `copyWith(isSideLying: true)` 能保留既有时间戳；手动运行 `flutter test`（我在本地尝试时命令被 Windows `终止批处理操作` 提示打断，需在 PowerShell 重新执行或改用 `cmd /c flutter test`）确保通过。

---

## 3. 后台提醒计时运行在主线程，易触发 ANR

```111:138:android/app/src/main/kotlin/com/example/flutter_application_1/FloatingWindowService.kt
private var reminderCheckHandler: Handler? = null
...
override fun onCreate() {
    ...
    reminderCheckHandler = mainHandler   // mainHandler 指向 Looper.getMainLooper()
    ...
}
```

```321:338:android/app/src/main/kotlin/com/example/flutter_application_1/FloatingWindowService.kt
private fun startReminderCheck() {
    reminderCheckRunnable = object : Runnable {
        override fun run() {
            try {
                if (isMonitoring && isSideLying && sideLyingSince != null) {
                    checkAndTriggerReminder()
                }
                reminderCheckHandler?.postDelayed(this, 1000)
            } catch (e: Exception) {
                e.printStackTrace()
                reminderCheckHandler?.postDelayed(this, 1000)
            }
        }
    }
    reminderCheckHandler?.post(reminderCheckRunnable!!)
}
```

- **现象/影响**：`reminderCheckHandler` 直接复用了主线程 `Handler`，而 `checkAndTriggerReminder()` 每秒都会执行 `SharedPreferences` I/O、震动、通知等重操作。后台服务的主线程负责处理系统回调，一旦这里耗时或阻塞，就会在 Android 13/14 上触发 `Application Not Responding`，悬浮窗被系统回收。
- **修改建议**：将提醒循环迁移到专用 `HandlerThread` 或 `CoroutineScope(Dispatchers.Default)`，仅把最终的 UI/通知更新切回主线程；`reminderCheckHandler` 可持有子线程 Looper，`onDestroy` 时安全退出。
- **验证方式**：修复后使用 `adb shell am kill com.example...` + 长时间后台运行，观察 `logcat` 无 ANR，悬浮窗不再丢失；可辅以 `StrictMode` 或 `adb shell am trace-ipc` 验证主线程无长任务。

---

## 4. Android 14 目标版本下缺少前台服务类型声明

```38:43:android/app/src/main/AndroidManifest.xml
<service
    android:name=".FloatingWindowService"
    android:enabled="true"
    android:exported="false" />
```

- **现象/影响**：Android 14 起（targetSdk ≥ 34）要求每个前台服务声明 `android:foregroundServiceType`，同时针对健康传感器应申请 `FOREGROUND_SERVICE_HEALTH`（或至少 `dataSync` 等合规类型）。当前 Manifest 没有任何类型声明，后续升级 targetSdk 时将直接收到 `ForegroundServiceStartNotAllowedException`，后台监测无法拉起。
- **修改建议**：在 `<service>` 节点增加 `android:foregroundServiceType="health"`（或更贴近业务的组合），并在 `<uses-permission>` 中补充 `android.permission.FOREGROUND_SERVICE_HEALTH`。若需兼容更老设备，可按系统版本动态降级。
- **验证方式**：提升 targetSdk 至 34 后在 Android 14 真机/模拟器上运行，确保 `ACTION_SHOW` 不再抛异常，前台通知与悬浮窗能够正常开启。

---

## 5. Flutter SDK 仍锁定开发版，阻碍依赖升级

```21:23:pubspec.yaml
environment:
  sdk: ^3.11.0-169.0.dev
```

- **现象/影响**：项目仍依赖 2023 年的 dev channel 版本，无法获得稳定分支（3.22+/3.24+）的修复，也导致许多三方包（如 `flutter_local_notifications` 17.x）在 `pubspec.lock` 中被迫停留在兼容旧 SDK 的版本。后续若要引用仅支持 stable 的插件会直接冲突。
- **修改建议**：将 SDK 约束调整为稳定范围，例如 `>=3.22.0 <4.0.0`，并执行 `flutter upgrade && flutter pub upgrade --major-versions`，随后修复由于 SDK 变更产生的编译告警。
- **验证方式**：更新后运行 `flutter --version` 确认处于 stable，再执行 `flutter analyze` 与 `flutter test`，确保无新的错误；真机验证监测流程正常。

---

如需我协助落地上述修改或补充更多自动化验证，欢迎继续告知。***

