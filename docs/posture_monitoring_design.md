## 侧躺监测与自定义姿势实现设计说明

本文档说明当前项目中“侧躺监测 + 自定义侧躺姿势”的整体设计和关键实现逻辑，面向开发和维护人员。

---

### 一、整体架构与数据流

- **原生前台服务 `FloatingWindowService`（Android/Kotlin）**
  - 持有加速度传感器监听、WakeLock、提醒计时线程、悬浮窗。
  - 负责：采样传感器 → 姿势判定（默认/自定义）→ 侧躺持续时间统计 → 触发震动 & 更新今日提醒次数 → 通过 `EventChannel` 把状态推给 Flutter。

- **Flutter 外壳 `_RootShellState`（`lib/main.dart`）**
  - 管理应用生命周期、设置加载/保存、UI、与原生服务通信。
  - 通过 `NativePostureStream` 监听原生推送的姿态事件，仅在前台根据同一套状态决定是否弹出前台提醒对话框。

- **自定义姿势仓库 `CustomPostureRepository`**
  - 用 `SharedPreferences` 持久化：
    - 是否启用自定义姿势：`use_custom_postures`
    - 多个 `CustomPosture`：包含归一化重力向量和原始加速度。
  - 通过 `MethodChannel('com.example.flutter_application_1/floating_window')` 将配置同步给原生服务。

- **自定义姿势录制页 `CustomPosturePage`**
  - 使用 `sensors_plus` 直接读取加速度，做指数平滑后，生成一条 `CustomPosture`，交由仓库保存并同步到原生。

- **提醒控制器 `ReminderController`**
  - 统一管理震动、后台通知、前台弹窗 UI。

数据流简要：

1. Flutter 设置页打开/关闭监测开关。
2. `_RootShellState` 通过 `MethodChannel` 启动（或关闭）原生前台服务和悬浮窗。
3. 原生服务采样传感器，按“默认算法或自定义算法”判断是否侧躺，并统计持续时间。
4. 原生服务在满足提醒条件时，触发震动、更新统计，并通过 `EventChannel` 推送事件到 Flutter。
5. Flutter 前台根据相同的 `PostureState`，在前台时弹出提醒对话框，后台时依赖原生通知。

---

### 二、监测何时开始与结束

#### 1. 开启监测

入口是 `_RootShellState._toggleMonitoring()`：

- 切换本地 `_monitoring` 状态并轻微震动反馈。
- 调用 `_settingsRepo.setMonitoring(next)` 持久化开关。
- 调用 `_ensureNativeMonitoringStarted()` 启动原生服务。
- 调用 `_handleMonitoringPipeline(next)`，按当前前台/后台状态决定：
  - 前台：开启前台定时器，仅用于前台对话框判定。
  - 后台：通过 `LifecycleCoordinator` 显示悬浮窗。

原生端在 `FloatingWindowService.onStartCommand(ACTION_SHOW)` 中：

- 若 `!isMonitoring`：
  - `startForegroundService()` → 启动前台服务；
  - `showFloatingWindow()` → 创建悬浮窗（默认右上角，可拖拽）；
  - `startSensorListening()` → 注册加速度传感器监听；
  - `startReminderCheck()` → 启动提醒计时线程。
- 若 `isMonitoring == true`：只更新悬浮窗 UI。

#### 2. 前台 / 后台切换

Flutter 在 `didChangeAppLifecycleState` 中：

- 委托 `LifecycleCoordinator.handleLifecycleChange(...)` 维护：
  - 当前是否在后台；
  - 悬浮窗是否需要显示/隐藏；
  - 何时发出 `ACTION_HIDE`（仅隐藏图标，不停服务）。
- 根据前后台控制前台计时器：
  - `resumed` 且已开启监测：`_startForegroundReminderCheck()`；
  - `paused` / `inactive`：`_stopForegroundReminderCheck()`。

#### 3. 关闭监测

- 关闭开关后 `_handleMonitoringPipeline(false)`：
  - Flutter 关闭前台计时器；
  - 通过 `LifecycleCoordinator` 隐藏悬浮窗；
  - 设置仓库中 `monitoring` 置为 `false`。
- 原生服务在合适时机（如 `onDestroy`）停止传感器监听、提醒线程、释放 WakeLock，并清理 `EventChannel`。

---

### 三、默认姿势检测算法

#### 1. 传感器采样与指数平滑

- 使用加速度传感器 `Sensor.TYPE_ACCELEROMETER`：
  - 前台使用 `SENSOR_DELAY_NORMAL`（约 50Hz）。
  - 后台使用 `SENSOR_DELAY_UI`（约 15Hz，节电）。

每次回调中：

1. 计算合加速度模长 \(g = \sqrt{ax^2 + ay^2 + az^2}\)，过小值直接忽略。
2. 归一化重力方向：
   - \(nx = ax / g\)，\(ny = ay / g\)，\(nz = az / g\)。
3. 使用指数平滑（\(\alpha = 0.15\)）减少抖动：
   - `avgNx = alpha * nx + (1 - alpha) * avgNx` 等。

#### 2. 大幅运动检测与重置

- 记录上一次重力模长 `lastG`，计算 `deltaG = |g - lastG|`。
- 若 `deltaG > 2.0`（阈值）：
  - 认为用户发生剧烈运动，直接重置：
    - 清空侧躺候选时间、连续计数和滑动窗口。
    - 如之前是侧躺状态，恢复为正常并通过 `EventChannel` 通知 Flutter。

这样可以避免在剧烈翻身时产生误判和“幽灵侧躺”状态残留。

#### 3. 默认侧躺判定规则

在未开启自定义姿势、或自定义姿势列表为空时：

- **方向判定：**
  - `abs(avgNz) < 0.8`：Z 轴重力较小，设备不再竖直对着地面。
  - `abs(avgNx) > 0.4 || abs(avgNy) > 0.4`：X/Y 轴之一较大，说明设备相对重力方向在“侧面”。
  - 组合为 `isScreenRoughlyVertical && isGravityMostlySide`。
- **原始值兜底判定：**
  - `abs(ax) > 6.5 && abs(az) < 5.0`：当某次采样 x 轴重力很大、z 轴较小，进一步确认侧躺。

最终 `isSide = isSideByDirection || isSideByRaw`。

#### 4. 稳定性：滑动窗口 + 连续计数

- 维护最近 N 次检测结果的滑动窗口（当前使用 `detectionWindowSize = 5`）。
- 同时统计：
  - 连续侧躺次数 `consecutiveSideCount`；
  - 连续正常次数 `consecutiveNormalCount`。
- 阈值：
  - 连续 `3` 次判断为侧躺 → 确认进入侧躺状态；
  - 连续 `5` 次判断为正常 → 确认退出侧躺状态。

这样可以显著过滤加速度瞬时噪声，让状态切换更稳定。

#### 5. 持续时间统计与提醒

1. 一旦稳定确认进入侧躺，记录 `sideLyingSince = now`。
2. 在独立的提醒线程中每秒检查一次：
   - 读取阈值秒数 `thresholdSeconds`（来自 SharedPreferences，与 Flutter 设置同步）；
   - 若 `elapsedSeconds < thresholdSeconds`：仅等待，不提醒；
   - 若 `elapsedSeconds >= thresholdSeconds`：
     - 触发震动；
     - 在服务内更新“今日提醒次数”（带日期判断和跨天重置）；
     - 通过 `sendStatsEvent` / `sendPostureEvent` 把新的统计和姿态状态推送给 Flutter。
3. 若后续稳定判定恢复为正常姿势：
   - 清空 `sideLyingSince`；
   - 将状态同步回 Flutter，以便前台 UI 更新。

---

### 四、自定义侧躺姿势实现

#### 1. 数据模型 `CustomPosture`

字段：

- `id`：唯一标识。
- `name`：用户自定义名称。
- `avgNx/avgNy/avgNz`：录制时平滑后的重力方向平均值。
- `rawAx/rawAy/rawAz`：录制末次的原始加速度，用于微调。
- `createdAt`：创建时间。

**相似度计算：**

使用加权欧氏距离：

- 归一化向量距离：\((nx-avgNx)^2 + (ny-avgNy)^2 + (nz-avgNz)^2\)；
- 原始加速度距离：\((ax-rawAx)^2 + (ay-rawAy)^2 + (az-rawAz)^2\)；
- 综合相似度：`normalizedDistance * 0.7 + rawDistance * 0.3`，数值越小越相似。

#### 2. 自定义姿势录制流程

在“设置 → 自定义侧躺姿势”中，用户可以：

1. 进入 `CustomPosturePage`。
2. 输入姿势名称（默认：“自定义姿势 N”）。
3. 点击“开始记录”：
   - 利用 `sensors_plus` 的加速度流；
   - 对每个样本计算 \(g\)、归一化重力向量，并对 `nx/ny/nz` 做指数平滑（同服务端，\(\alpha = 0.15\)）；
   - 保留最后一帧的原始 `ax/ay/az`；
   - 统计样本个数 `_sampleCount`。
4. 至少采样 `_minSamples = 30`（约 1 秒），否则不允许保存。
5. 点击“保存姿势”：
   - 创建一个 `CustomPosture`；
   - 调用 `CustomPostureRepository.addCustomPosture(...)` 保存到本地；
   - 仓库再 `_syncToNative()` 把数据下发到原生服务。

#### 3. 仓库存储与同步

- 使用 `SharedPreferences` 存储：
  - `use_custom_postures`：是否启用自定义姿势；
  - `custom_postures`：所有自定义姿势的 JSON 列表。
- 所有写入操作（添加、删除、清空、开关）都会：
  1. `_saveToPrefs()` 写入本地；
  2. `_syncToNative()` 挂到 `MethodChannel` 调用，用 JSON 把：
     - `useCustomPostures`；
     - 每个姿势的 `avgNx/avgNy/avgNz/rawAx/rawAy/rawAz/id/name`；
     下发给原生。
- 原生在 `MainActivity` 中解析后，通过 `Intent`/广播把新的配置发给 `FloatingWindowService`。

#### 4. 自定义姿势检测算法（服务端）

在 `FloatingWindowService.onSensorChanged` 中：

- 若 `useCustomPostures == true` 且 `customPostures` 列表不为空：
  1. 对所有 `CustomPostureData` 调用 `calculateSimilarity(...)`；
  2. 找到相似度最小的一个 `bestMatch`；
  3. 若 `bestSimilarity < 0.5`（阈值），视为匹配自定义姿势 → `isSide = true`；
  4. 否则视为不匹配 → `isSide = false`。
- 当 `useCustomPostures == false` 或列表为空时，自动回退到默认系统姿势算法。

“恢复默认算法”操作会调用仓库的 `clearAllCustomPostures()`：

- 清空列表；
- 将 `_useCustomPostures` 置 `false`；
- 同步至原生后，服务端自动回到默认算法分支。

---

### 五、前台 / 后台提醒策略

#### 1. 后台提醒（原生主导）

- 检测与计时均由 `FloatingWindowService` 完成。
- 超过阈值时：
  - 在服务中触发震动。
  - 通过 `ReminderController` 的后台路径发送通知（Android 通知栏）。
  - 更新 SharedPreferences 中的今日提醒次数，并通过 `EventChannel` 通知 Flutter。

#### 2. 前台提醒（Flutter UI 主导）

- 姿态与持续时间信息通过 `NativePostureStream` 推送到 Flutter：
  - `PostureState(isSideLying, sideLyingSince)`；
  - 今日提醒次数通过 stats 流。
- Flutter 在前台时运行 `_startForegroundReminderCheck()`：
  - 每秒检查一次：
    - 若当前为侧躺；
    - 且未处于免打扰时段；
    - 且从 `sideLyingSince` 起已超过本地阈值；
    - 且当前没有对话框在显示；
  - 则调用 `ReminderController.triggerReminder(isInBackground: false)`：
    - 震动；
    - 弹出毛玻璃风格的提醒对话框。

这样可以确保：**同一套姿态/时间信息在前后台的一致性**，同时给前台用户提供更友好的交互体验。

---

### 六、性能与稳定性设计要点

- **线程与计时**
  - 使用独立的 `HandlerThread("ReminderCheckThread")` 做秒级提醒检查，避免阻塞主线程。
  - 传感器监听只占用系统提供的传感器线程，无额外新建线程。

- **功耗控制**
  - 前台使用较高采样频率以保证体验，后台使用较低频率节省电量。
  - WakeLock 使用 10 分钟超时 + 每 5 分钟续期，停止监测与服务销毁时主动释放。

- **日志与 Release 行为**
  - Flutter 端：`AppLogger.d/i/w` 仅在 Debug 模式输出，Release 只输出简化的错误信息。
  - 原生端：大部分 `Log.d/e` 包裹在 `BuildConfig.DEBUG` 判断内，Release 构建时基本不产生调试日志。

整体上，这套实现兼顾了：

- 前后台行为一致性；
- 默认算法 + 用户自定义算法的灵活切换；
- 足够的稳定性（平滑 + 滑动窗口 + 连续计数 + 大幅运动重置）；
- 对耗电、内存和线程数量的控制，减少被系统强杀的风险。


