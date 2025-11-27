# 后台监测问题修复说明

## 问题分析

### 原始问题
当应用进入后台显示悬浮窗后，回到首页面十几秒后，悬浮窗消失，应用好像停止了。

### 根本原因
1. **悬浮窗服务不是前台服务**：普通Service容易被系统回收
2. **传感器监听在Flutter层**：当Flutter应用进程被系统回收时，传感器监听就停止了
3. **缺少进程保活机制**：没有WakeLock保持CPU运行

## 解决方案

### 1. 将悬浮窗服务改为前台服务
- 在`AndroidManifest.xml`中声明`foregroundServiceType="health"`
- 在服务启动时调用`startForeground()`显示通知
- 使用`START_STICKY`标志确保服务被系统杀死后自动重启

### 2. 在原生服务中实现传感器监听
- 在`FloatingWindowService`中实现`SensorEventListener`接口
- 直接在原生层监听加速度传感器
- 实现与Flutter层相同的侧躺检测逻辑
- 实时更新悬浮窗状态

### 3. 添加WakeLock保持CPU运行
- 使用`PARTIAL_WAKE_LOCK`保持CPU运行
- 设置10分钟超时，防止永久占用
- 在服务停止时释放WakeLock

### 4. 优化生命周期管理
- 应用进入后台时：停止Flutter层传感器监听，启动原生服务监测
- 应用回到前台时：停止原生服务监测，恢复Flutter层传感器监听
- 避免重复监听，节省资源

## 实现细节

### 前台服务通知
```kotlin
val notification = NotificationCompat.Builder(this, CHANNEL_ID)
    .setContentTitle("枕边哨")
    .setContentText("正在后台监测你的姿势")
    .setSmallIcon(android.R.drawable.ic_dialog_info)
    .setOngoing(true)
    .setPriority(NotificationCompat.PRIORITY_LOW)
    .build()
```

### 传感器监听
```kotlin
override fun onSensorChanged(event: SensorEvent?) {
    // 实现与Flutter层相同的侧躺检测逻辑
    // 实时更新悬浮窗状态
}
```

### WakeLock管理
```kotlin
wakeLock = powerManager.newWakeLock(
    PowerManager.PARTIAL_WAKE_LOCK,
    "FloatingWindowService::WakeLock"
)
wakeLock?.acquire(10*60*1000L) // 10分钟超时
```

## 优势

1. **稳定性**：前台服务优先级高，不易被系统回收
2. **持续性**：原生层监听不受Flutter进程影响
3. **资源优化**：前后台切换时避免重复监听
4. **用户体验**：悬浮窗持续显示，状态实时更新

## 注意事项

1. **电池优化**：建议用户在系统设置中关闭应用的电池优化
2. **自启动权限**：部分厂商ROM需要开启自启动权限
3. **通知权限**：Android 13+需要通知权限才能显示前台服务通知
4. **WakeLock超时**：10分钟超时后需要续期（当前实现中服务会保持运行）

## 测试建议

1. 开启监测后，进入后台
2. 等待几分钟，确认悬浮窗仍然显示
3. 侧躺测试，确认悬浮窗状态实时更新
4. 回到前台，确认监测正常切换
5. 长时间后台运行测试，确认服务不被回收

