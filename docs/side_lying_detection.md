### 侧躺监测判定逻辑说明

#### 1. 使用的传感器与数据

- **传感器**: `AccelerometerEvent`（加速度计），来自 `sensors_plus`。
- **原始数据**:  
  - `event.x`, `event.y`, `event.z`（单位约为 m/s²，包含重力加速度分量）。
- **派生数据**:
  - 重力模长  
    \[
    g = \sqrt{x^2 + y^2 + z^2}
    \]
  - 归一化重力向量（只看方向，不看大小）  
    \[
    n_x = \frac{x}{g},\quad n_y = \frac{y}{g},\quad n_z = \frac{z}{g}
    \]

#### 2. 相关状态变量

在 `lib/main.dart` 的 `_RootShellState` 中维护以下状态：

- `_monitoring: bool`  
  是否开启姿态监测。
- `_vibrationEnabled: bool`  
  是否允许震动反馈（设置页开关）。
- `_thresholdSeconds: int`  
  侧躺持续多少秒后触发健康提醒（默认 **5 秒**，可在设置页调整为 5–120 秒）。
- `_isSideLying: bool`  
  当前是否处于“**已确认的稳定侧躺**”状态。
- `_sideLyingSince: DateTime?`  
  从什么时候开始连续处于“稳定侧躺状态”（仅在 `_isSideLying == true` 时非空，用于健康提醒计时）。
- `_sideCandidateSince: DateTime?`  
  最近一次进入“疑似侧躺区间”的时间，用于“稳定期”判断（例如连续 2 秒都在侧躺区间才确认）。
- `_lastG: double?`  
  上一帧的重力模长，用于检测较大的姿势变化（Δg 阈值）。
- `_avgNx, _avgNy, _avgNz, _avgG: double`  
  通过指数平滑得到的重力方向/模长（低通滤波），弱化抖动。
- `_todayRemindCount: int` / `_today: DateTime`  
  今日提醒次数和日期（跨天自动重置）。

#### 3. 侧躺姿势判定（实时）

位置：`_startSensorListening()` 中对 `accelerometerEvents` 的监听。

##### 3.1 读取与预处理

```dart
final ax = event.x;
final ay = event.y;
final az = event.z;
final g = sqrt(ax * ax + ay * ay + az * az);

if (g < 1e-3) {
  // 数据异常，直接忽略
  return;
}
```

##### 3.2 归一化重力方向 + 低通滤波

```dart
final nx = ax / g;
final ny = ay / g;
final nz = az / g;
```

- `nx, ny, nz` 范围大致在 \([-1, 1]\)，只表示重力方向，不表示大小。

然后对这些量进行指数平滑（低通滤波）：

```dart
const alpha = 0.15; // 越小越平滑
_avgNx = alpha * nx + (1 - alpha) * _avgNx;
_avgNy = alpha * ny + (1 - alpha) * _avgNy;
_avgNz = alpha * nz + (1 - alpha) * _avgNz;
_avgG = alpha * g + (1 - alpha) * _avgG;
```

这样判定逻辑使用的是“平滑后的方向”，短时间的小幅摆动不会立刻改变姿态判断。

##### 3.3 Δg 阈值：检测大幅姿势变化

为捕捉“突然翻身 / 坐起”等大动作，使用前后两帧的 g 差值：

```dart
double deltaG = 0;
if (_lastG != null) {
  deltaG = (g - _lastG!).abs();
}
_lastG = g;

if (deltaG > 0.8) {
  // 认为发生了较大姿势变化，清空候选与确认状态
  _sideCandidateSince = null;
  if (_isSideLying) {
    _isSideLying = false;
    _sideLyingSince = null;
  }
}
```

- 阈值 `0.8` 大约对应一次比较明显的加速度变化，可视为“一个新的姿势阶段”的开始。
- 这样在大动作之后，会重新进入“候选 → 稳定 → 确认”的流程。

##### 3.4 判定 1：基于“平滑重力方向”的侧躺判断（主逻辑）

设计目标：  
- 排除“平放在桌面 / 天花板下”的情况（那是 z 轴占主导）；  
- 捕捉“手机被明显侧着拿着”的情况（x 或 y 方向占主导），对应用户身体大概率是侧躺。

实现：

```dart
final bool isScreenRoughlyVertical = _avgNz.abs() < 0.8;
final bool isGravityMostlySide =
    _avgNx.abs() > 0.4 || _avgNy.abs() > 0.4; // 左右或前后方向占主导
final bool isSideByDirection =
    isScreenRoughlyVertical && isGravityMostlySide;
```

含义：
- `isScreenRoughlyVertical`：z 分量不占主导，说明设备不是“平躺”状态；
- `isGravityMostlySide`：x / y 分量有明显一轴较大，说明手机相对重力方向有明显侧偏。

##### 3.5 判定 2：基于原始加速度值的宽松判断（兼容补充）

为兼容部分设备/姿势，保留一套简单的原始值判定逻辑：

```dart
final bool isSideByRaw = ax.abs() > 6.5 && az.abs() < 5.0;
```

- x 分量较大且 z 分量较小 → 重力主要沿手机“侧向”分布。

##### 3.6 综合判定结果

```dart
final isSide = isSideByDirection || isSideByRaw;
```

只要两套判定逻辑之一认为是“侧躺”，就视为当前处于侧躺姿态。

##### 3.7 稳定期 + 状态更新与首次进入反馈

```dart
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
    // 确认进入侧躺的时间点，用于后续健康提醒计时
    _sideLyingSince = now;
    // 第一次进入“稳定的侧躺状态”时的轻量反馈
    _vibrateOnce(durationMs: 50);
    _showSideStartDialog();
  }
} else {
  // 退出候选与确认状态
  _sideCandidateSince = null;
  _isSideLying = false;
  _sideLyingSince = null;
}
```

行为总结：
- 只有当 **连续处于“疑似侧躺区间” ≥ 2 秒** 后，才将 `_isSideLying` 置为 `true`，即进入“稳定侧躺状态”；
- 进入稳定侧躺的瞬间：
  - 记录 `_sideLyingSince`；
  - 轻微震动一次；
  - 底部显示轻提示 `_showSideStartDialog()`；
- 只要 `isSide` 持续为 `true`，就保持 `_isSideLying == true`，并在首页底部持续显示“正在检测侧躺姿势”的玻璃卡片；
- 若姿势退出 `isSide` 或 Δg 超过阈值，则同时重置候选 + 确认状态。

#### 4. 持续时间阈值与健康提醒

位置：`_maybeTriggerReminder()`，通过 `_checkTimer` 每秒调用一次。

前置过滤：

```dart
if (!_monitoring || !_isSideLying || _sideLyingSince == null) return;
if (_isInDnd(now)) return; // 处于免打扰时段则直接返回
```

其中 `_isInDnd(now)` 会根据设置页配置的 `TimeOfDay dndStart / dndEnd` 判断是否在免打扰时间段（支持跨午夜，如 23:00–07:00）。

##### 4.1 计算连续侧躺时间

```dart
final elapsed = now.difference(_sideLyingSince!).inSeconds;
if (elapsed < _thresholdSeconds) return;
```

- `_thresholdSeconds` 为设置项（默认 5 秒，可在设置页调整 5–120 秒）。
- 只有当连续处于 `_isSideLying == true` 且 **持续时间 ≥ 阈值** 时才会继续执行提醒逻辑。

##### 4.2 触发提醒与统计

```dart
_sideLyingSince = now; // 重置起点，避免短时间内多次触发

_todayRemindCount += 1;
await _persistTodayStats(); // 记录今日提醒次数

// 震动（如果允许且设备支持）
if (_vibrationEnabled &&
    ((await Vibration.hasVibrator()) ?? false)) {
  Vibration.vibrate(pattern: [0, 120, 60, 120]);
}

_showReminderDialog(); // 弹出健康提醒弹窗
```

效果：
- 每次超过阈值都会：
  - 累加“今日提醒次数”；
  - 触发一组明显的震动反馈；
  - 以模态毛玻璃方式弹出健康提醒弹窗（需要用户点击“知道了”关闭）。
- 由于 `_sideLyingSince` 被重置为 `now`，用户如果继续保持侧躺，后续仍会按每个“连续阈值周期”再次提醒，直到姿势改变。

#### 5. 不同层级的用户反馈

1. **开始监测**
   - 当用户在首页点击“开始监测”：
     - `_monitoring` 置为 `true`，开始订阅加速度数据；
     - 轻微震动一次（`_vibrateOnce(durationMs: 60)`）。

2. **进入侧躺状态（首次）**
   - `_isSideLying` 由 `false` → `true`：
     - 轻微震动一次提醒；
     - 触发 `_showSideStartDialog()`：底部玻璃拟态轻提示卡片，说明“已检测到侧躺，并开始计时”；
     - 首页底部长期显示“正在检测侧躺姿势”的卡片，只要保持侧躺就不消失。

3. **持续侧躺时间达到阈值**
   - 连续时间 ≥ `_thresholdSeconds`（5–120 秒）：
     - 更新“今日提醒次数”并持久化；
     - 使用一组 pattern 强度更明显的震动；
     - 弹出模态健康提醒弹窗 `_showReminderDialog()`（“姿势不对哦～”）。

4. **退出侧躺状态**
   - 当用户调整姿势（不满足 `isSide`）：
     - `_isSideLying` 变为 `false`；
     - `_sideLyingSince` 置空；
     - 首页底部的“正在检测侧躺姿势”卡片自动消失。

#### 6. 可调参数与后续优化方向

- **可在代码中调整的核心阈值**（需要改 Dart 代码）：
  - `isScreenRoughlyVertical`: 当前为 `nz.abs() < 0.8`。
  - `isGravityMostlySide`: 当前为 `nx.abs() > 0.4 || ny.abs() > 0.4`。
  - `isSideByRaw`: 当前为 `ax.abs() > 6.5 && az.abs() < 5.0`。
- **可在 UI 中调整的阈值**：
  - `_thresholdSeconds`: 设置页 Slider（5–120 秒），用于控制“侧躺持续多久才触发健康提醒”。

未来如需进一步优化，可以：
- 针对特定机型采集一批 `ax, ay, az` 的实际数据样本，微调上述常数；
- 引入低通滤波 / 滑动窗口，对短暂晃动进行平滑，进一步减少误判；
- 按“左侧躺 / 右侧躺 / 仰卧侧拿”的不同模式分别设定阈值。


