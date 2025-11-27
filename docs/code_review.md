# 代码全面检查记录（2025-11-27）

> 目标：列出当前版本 Flutter + Android 双端存在的主要问题，方便按模块修正。

## Flutter 层

1. `lib/main.dart` 中 `ColorScheme.fromSeed` 仍写入 `background` 字段（`background: background`），在 Flutter 3.24+ 已被弃用，应改用 `surface`/`surfaceTint`；对应同文件的 `accelerometerEvents` 也被标记为弃用，需要迁移到 `accelerometerEventStream()`，否则未来 SDK 升级直接报错。
2. `_maybeTriggerReminder()`（`lib/main.dart`）对震动能力的判断写成 `((await Vibration.hasVibrator()) ?? false)`，但 `hasVibrator()` 返回不可为空的 `bool`，导致 dead code 和 `dead_null_aware_expression` 警告；相同写法在第 421 行重复一次，应改为直接判断布尔值，顺便复用一次 `hasVibrator()` 结果减少 I/O。
3. UI 层大量调用 `Color.withOpacity()`（`lib/main.dart`, `lib/pages/home_page.dart`, `lib/pages/settings_page.dart`, `lib/widgets/glass_card.dart`），Flutter 3.24 开始推荐 `color.withValues(alpha: …)`，否则编译器持续输出 `deprecated_member_use`；建议集中封装颜色常量或扩展方法。
4. `RootShell` 仍直接依赖 `accelerometerEvents` 并在 `initState` 时立即 `start()`，与 `SettingsRepository` 的 `notifyListeners()` 相互触发多次 `setState`。可考虑使用 `ValueListenableBuilder`/`ChangeNotifierProvider` 让页面分离状态，而不是在同一个 `State` 持有所有逻辑，降低 UI jank。
5. 单元测试运行时持续打印 `MissingPluginException`（`test/settings_repository_test.dart` → `SettingsRepository._sendSettingsToNative()`），虽然被 try/catch 吞掉，但测试输出噪声严重。可在测试环境或 `kIsWeb`/`!Platform.isAndroid` 时短路，不调 MethodChannel。

## 原生服务层

1. `FloatingWindowService` 在 `startSensorListening()` 里 `wakeLock?.acquire(10*60*1000L)` 后就没有继续续期，`renewWakeLock()` 方法从未调用；10 分钟后锁会过期，传感器监听可能被系统挂起。需要在定时任务里周期性调用 `renewWakeLock()`，或改成 `acquire()` + `setReferenceCounted(false)`。
2. 同一个方法中每次注册传感器都新建 `Handler(Looper.getMainLooper())` 再 `post`，创建对象频率高。建议持有单例 `mainHandler`，减少 GC。
3. `updateSettingsFromIntent()` 只处理广播里带来的配置，但 `SettingsRepository` 通过 MethodChannel 发送的 payload 包含 `monitoring` 字段，MainActivity `syncSettingsToService()` 却完全忽略它，导致服务无法根据 Dart 端的开关去自停，必须依赖额外的 `ACTION_HIDE` 调度，容易出现状态不同步。
4. `showFloatingWindow()` 仅在 `LayoutParams` 上设置 `FLAG_NOT_FOCUSABLE | FLAG_LAYOUT_IN_SCREEN`，没有 `FLAG_NOT_TOUCH_MODAL`/`FLAG_LAYOUT_NO_LIMITS`，部分机型会导致窗口无法完全拖出屏幕。可根据需求补充 flag。
5. `checkAndTriggerReminder()` 在 DND 期间直接 `sideLyingSince = now`，相当于用户整晚侧躺也不会恢复提示。更合理的做法是保持原起始时间或记录 DND 退出后再重新计时。

## 依赖与工具

1. `pubspec.yaml` 的 `environment.sdk` 固定在 `3.11.0-169.0.dev`，属于早期 dev 渠道，稳定渠道早已更新。建议至少切到 `>=3.22.0 <4.0.0` 之类的 stable 约束，避免依赖解析受限。
2. `flutter analyze` 当前有 30 条 warning/info，集中在上面提到的 deprecated API 与 dead code，需要在下一次提交前清空；否则 CI/代码评审难以发现新的回归。
3. 建议在仓库根目录增加 `melos`/`justfile` 或简单的 `scripts/analyze.sh`，统一执行 `flutter analyze && flutter test && flutter pub outdated`，避免本地环境遗漏。

## 行动建议

1. **优先清理 Flutter 警告**：统一升级 `sensors_plus` 用法、封装 `withValues` 扩展、修复震动判断。
2. **补齐原生服务续航逻辑**：实现 `renewWakeLock()` 调度、同步 `monitoring` 状态，验证后台长时间运行。
3. **规范平台通道调用**：在测试/非 Android 环境不触发 `MethodChannel`，必要时通过 `PlatformInterface` 注入 Mock，确保单元测试无噪音。

## Flutter 层修复进度（2025-11-27）

- `lib/main.dart` 迁移到 `accelerometerEventStream()` 并将 `ColorScheme.fromSeed` 的 `background` 参数移除，避免 SDK 升级警告。
- `withOpacity` 全部替换为 `withValues(alpha: …)`（`main.dart`, `home_page.dart`, `settings_page.dart`, `glass_card.dart`），`flutter analyze` 不再提示弃用 API。
- 震动逻辑集中在 `_vibrateOnce` / `_vibratePattern`，统一检查 `hasVibrator()`，消除 `dead_code` 告警并减少重复判断。

落实以上项后再运行 `flutter analyze` 作为验收，确保 warning=0；原生层可借助 `adb shell dumpsys sensorservice` 观察 10 分钟后仍有监听，确认 WakeLock 生效。

