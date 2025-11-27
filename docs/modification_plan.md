## 分步骤改造方案（MVP 阶段）

下面的步骤按“由浅入深”排列，每个步骤都可以单独执行和测试；即便暂时不做后面的步骤，也不会影响前面步骤已经交付的效果。

---

### 步骤 1：梳理设置持久化与缓存
- **痛点**：`lib/main.dart` 每秒从 `SharedPreferences` 重新实例化并读取配置，Android 服务也重复访问同一存储，造成 I/O 抖动和状态不一致隐患。
- **动作**：
  1. 在 `lib/services/settings_repository.dart`（新建）封装单例访问，启动时一次性 `await SharedPreferences.getInstance()`，后续通过内存缓存 + `notifyListeners()` 暴露给 UI。
  2. `lib/main.dart` 里替换直接调用 `SharedPreferences` 的位置，仅在设置修改时 `await repo.save(...)`。
  3. 为统计数据和监测开关增加简单的 `ValueNotifier`/`ChangeNotifier`，避免定时器反复读取磁盘。
- **验证**：运行 `flutter test test/settings_repository_test.dart`（新建简易单元测试）确认读取/写入逻辑；在真机上切换震动与阈值，观察刷新是否即时。

---

### 步骤 2：提取姿态检测核心算法为 Dart Service
- **痛点**：前台 `_RootShellState` 与 Kotlin `FloatingWindowService` 同时维护一套检测逻辑，后续阈值或算法调整必须改两遍。
- **动作**：
  1. 在 `lib/services/posture_monitor.dart` 创建纯 Dart 类，接收 `Stream<AccelerometerEvent>`，对外暴露 `Stream<PostureState>`。
  2. `_RootShellState` 改为订阅该服务的输出，仅负责 UI。
  3. 保持 Android 原生逻辑暂不动，但把算法常量集中到新类，后续 Kotlin 可引用（见步骤 4）。
- **验证**：编写 `test/posture_monitor_test.dart`，模拟加速度输入，覆盖“稳定侧躺 ≥ 阈值触发”“姿势恢复立即复位”等场景；运行应用确认前台提醒仍能触发。

---

### 步骤 3：清理 Flutter Background Service 的半成品配置
- **痛点**：`_initializeBackgroundService` 只做配置从未 `startService()`，导致依赖白占；同时原生 `FloatingWindowService` 已承担后台职责。
- **动作**（两选一，按时间决定）：
  - **A. 精简方案**：直接移除 `flutter_background_service` 相关依赖、初始化与 `onStart` 回调，改为仅使用原生前台服务。
  - **B. 整合方案**：在监测开关开启时调用 `service.startService()`，并决定它与原生服务的分工（例如 Flutter 负责传感器，原生只负责悬浮窗）。
- **验证**：执行 `flutter pub run dart_code_metrics:metrics .` 确认无未使用 import；在真机上开启/关闭监测，查看后台通知或悬浮窗是否符合预期。

---

### 步骤 4：打通设置同步与免打扰逻辑到原生服务
- **痛点**：Kotlin 中的 `isInDnd`、`vibrationEnabled` 未正确读取 Dart 端配置，导致后台提醒无视免打扰与震动开关。
- **动作**：
  1. 利用步骤 1 的 `SettingsRepository` 增加 `broadcastSettings()`，通过 `MethodChannel` 或 `SharedPreferences` 批量写入原生读取的键。
  2. `android/app/src/main/.../FloatingWindowService.kt` 在 `checkAndTriggerReminder()` 里读取 `dnd_start_minutes`、`dnd_end_minutes`、`vibration_enabled` 并应用。
  3. 若走 `MethodChannel`，在 Kotlin 侧添加 `EventChannel` 监听设置变更，避免轮询。
- **验证**：开启监测后设定免打扰时间为当前时间段，确认不会再弹提醒；关闭震动后只出现通知无震感。

---

### 步骤 5：拆分 UI 层结构与可测试性
- **痛点**：`lib/main.dart` 体量 ~2k 行，`_RootShellState` 同时处理 UI、权限、监测、统计、悬浮窗，维护成本高。
- **动作**：
  1. 将首页、设置页分别移动到 `lib/pages/home_page.dart`、`lib/pages/settings_page.dart`; Root shell 仅负责导航与全局依赖注入。
  2. 把权限/悬浮窗引导移入 `lib/services/permission_coordinator.dart`，UI 通过 `FutureBuilder` 或 `Provider` 拉取状态。
  3. 在 `docs/architecture.md`（新建）记录“UI 层 / Service 层 / 原生服务”职责划分，方便后续协作。
- **验证**：运行 `flutter analyze` 确保无未使用成员；补充最少 1-2 个 widget 测试覆盖导航与状态展示。

---

这些步骤可以分阶段落地，建议每完成一步就打 Tag 或提交一个小版本，便于回滚与测试。若希望进一步聚焦某一步骤，我可以继续细化实现细节或提供示例代码。

