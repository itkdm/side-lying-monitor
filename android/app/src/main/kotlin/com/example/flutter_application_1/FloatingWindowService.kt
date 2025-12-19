package com.example.flutter_application_1

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.graphics.PixelFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.Surface
import android.widget.ImageView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.math.atan2

class FloatingWindowService : Service(), SensorEventListener {
    companion object {
        // 常量定义
        const val ACTION_SHOW = "com.example.flutter_application_1.SHOW_FLOATING_WINDOW"
        const val ACTION_HIDE = "com.example.flutter_application_1.HIDE_FLOATING_WINDOW"
        const val ACTION_UPDATE_STATE = "com.example.flutter_application_1.UPDATE_STATE"
        const val ACTION_SETTINGS_UPDATED = "com.example.flutter_application_1.SETTINGS_UPDATED"
        const val EXTRA_IS_SIDE_LYING = "is_side_lying"
        const val EXTRA_MONITORING = "extra_monitoring"
        const val EXTRA_VIBRATION_ENABLED = "extra_vibration_enabled"
        const val EXTRA_THRESHOLD_SECONDS = "extra_threshold_seconds"
        const val EXTRA_DND_START_MINUTES = "extra_dnd_start_minutes"
        const val EXTRA_DND_END_MINUTES = "extra_dnd_end_minutes"
        const val EXTRA_DND_ENABLED = "extra_dnd_enabled"
        private const val CHANNEL_ID = "floating_window_service_channel"
        private const val NOTIFICATION_ID = 1001
        
        // EventChannel相关
        @Volatile
        private var eventSink: EventChannel.EventSink? = null
        
        fun setEventSink(sink: EventChannel.EventSink?) {
            eventSink = sink
        }
        
        private fun sendPostureEvent(isSideLying: Boolean, sideLyingSince: Long?) {
            val sink = eventSink ?: return
            // EventChannel必须在主线程调用，使用Handler切换到主线程
            val mainHandler = Handler(Looper.getMainLooper())
            mainHandler.post {
                try {
                    val event = mapOf(
                        "isSideLying" to isSideLying,
                        "sideLyingSince" to (sideLyingSince ?: 0)
                    )
                    sink.success(event)
                } catch (e: Exception) {
                    android.util.Log.e("FloatingWindow", "Error sending posture event: ${e.message}", e)
                }
            }
        }
        
        private fun sendStatsEvent(todayRemindCount: Int) {
            val sink = eventSink ?: return
            // EventChannel必须在主线程调用，使用Handler切换到主线程
            val mainHandler = Handler(Looper.getMainLooper())
            mainHandler.post {
                try {
                    val event = mapOf(
                        "type" to "stats",
                        "todayRemindCount" to todayRemindCount
                    )
                    sink.success(event)
                } catch (e: Exception) {
                    android.util.Log.e("FloatingWindow", "Error sending stats event: ${e.message}", e)
                }
            }
        }
    }
    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var windowParams: WindowManager.LayoutParams? = null
    private var isSideLying = false
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // 传感器相关
    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var wakeLock: PowerManager.WakeLock? = null
    
    // 姿态检测相关
    private var avgNx = 0.0
    private var avgNy = 0.0
    private var avgNz = 1.0
    private var lastG: Double? = null
    private var sideCandidateSince: Long? = null
    private var sideLyingSince: Long? = null
    private var isMonitoring = false
    private var isInForeground = false // 是否在前台（用于调整采样频率）
    private var lastDebugLogTime: Long = 0L // 节流用的调试日志时间戳
    
    // 检测稳定性相关：使用滑动窗口记录最近的检测结果
    private val sideDetectionWindow = mutableListOf<Boolean>() // 最近N次的检测结果
    private val detectionWindowSize = 5 // 目前不再依赖计数窗口，保留以便未来扩展
    private var consecutiveSideCount = 0 // 不再作为主判定依据
    private var consecutiveNormalCount = 0 // 不再作为主判定依据

    // 使用基于时间的稳定判定，避免前后台采样率差异带来的体验漂移
    private var lastSampleTimeMs: Long? = null
    private var sideHoldMs: Long = 0L
    private var normalHoldMs: Long = 0L
    
    // 显示方向相关（用于将重力映射到“屏幕坐标系”，减少横屏误判）
    private var displayRotation: Int = Surface.ROTATION_0
    
    // 自定义姿势相关
    private data class CustomPostureData(
        val id: String,
        val name: String,
        val avgNx: Double,
        val avgNy: Double,
        val avgNz: Double,
        val rawAx: Double,
        val rawAy: Double,
        val rawAz: Double
    ) {
        fun calculateSimilarity(nx: Double, ny: Double, nz: Double, ax: Double, ay: Double, az: Double): Double {
            val normalizedDistance = 
                (nx - avgNx) * (nx - avgNx) +
                (ny - avgNy) * (ny - avgNy) +
                (nz - avgNz) * (nz - avgNz)
            val rawDistance = 
                (ax - rawAx) * (ax - rawAx) +
                (ay - rawAy) * (ay - rawAy) +
                (az - rawAz) * (az - rawAz)
            // 更强调重力方向的一致性，将原始加速度权重调低，降低手抖/轻微移动的影响
            return normalizedDistance * 0.9 + rawDistance * 0.1
        }
    }
    private var useCustomPostures = false
    private val customPostures = mutableListOf<CustomPostureData>()
    
    // 提醒相关
    private var reminderThread: HandlerThread? = null
    private var reminderCheckHandler: Handler? = null
    private var reminderCheckRunnable: Runnable? = null
    private var vibrator: Vibrator? = null
    private var sharedPreferences: SharedPreferences? = null
    private var vibrationEnabled = true
    private var dndStartMinutes = 23 * 60
    private var dndEndMinutes = 7 * 60
    private var thresholdSecondsCache = 5
    private var dndEnabled = false

    private val settingsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_SETTINGS_UPDATED) {
                android.util.Log.d("FloatingWindow", "Received settings update broadcast")
                updateSettingsFromIntent(intent)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        // 读取当前显示方向，用于后续重力分量重映射
        try {
            @Suppress("DEPRECATION")
            displayRotation = windowManager?.defaultDisplay?.rotation ?: Surface.ROTATION_0
        } catch (_: Exception) {
            displayRotation = Surface.ROTATION_0
        }
        sensorManager = getSystemService(SENSOR_SERVICE) as SensorManager
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        
        // 创建WakeLock保持CPU运行
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "FloatingWindowService::WakeLock"
        )
        
        // 初始化震动器
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vibrator = vibratorManager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        
        // 初始化SharedPreferences
        sharedPreferences = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        loadSettingsFromPrefs()
        try {
            registerReceiver(settingsReceiver, IntentFilter(ACTION_SETTINGS_UPDATED))
        } catch (e: Exception) {
            android.util.Log.e("FloatingWindow", "Failed to register settings receiver: ${e.message}", e)
        }
        
        // 创建独立线程用于定时检查提醒，避免阻塞主线程
        reminderThread = HandlerThread("ReminderCheckThread").apply { start() }
        reminderCheckHandler = reminderThread?.looper?.let { Handler(it) }
        
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        android.util.Log.d(
            "FloatingWindow",
            "onStartCommand: action=${intent?.action}, isMonitoring=$isMonitoring"
        )
        when (intent?.action) {
            ACTION_SHOW -> {
                loadSettingsFromPrefs()
                if (!isMonitoring) {
                    isMonitoring = true
                    // 确保在任何耗时操作之前尽早进入前台，避免启动超时
                    startForegroundService()
                    showFloatingWindow()
                    startSensorListening()
                    startReminderCheck()
                } else {
                    // 如果已经在监测，只更新悬浮窗状态
                    updateFloatingWindowState(isSideLying)
                }
            }
            ACTION_HIDE -> {
                // 仅隐藏悬浮窗，但保持前台服务与传感器监测继续运行
                // 这样在 App 前台时依然可以通过 EventChannel 推送姿态状态，
                // 只是不再在其他应用上显示悬浮窗。
                hideFloatingWindow()
                android.util.Log.d(
                    "FloatingWindow",
                    "ACTION_HIDE: only hiding floating window, isMonitoring=$isMonitoring"
                )
            }
            ACTION_UPDATE_STATE -> {
                loadSettingsFromPrefs()
                val sideLying = intent.getBooleanExtra(EXTRA_IS_SIDE_LYING, false)

                if (!isMonitoring) {
                    // 如果服务是通过 UPDATE_STATE 首次启动的，也必须立即进入前台，避免超时异常
                    isMonitoring = true
                    startForegroundService()
                    showFloatingWindow()
                    startSensorListening()
                    startReminderCheck()
                }

                updateFloatingWindowState(sideLying)
            }
            else -> {
                // 兜底：若因其他 action 启动服务，也尽快进入前台以避免系统超时
                if (!isMonitoring) {
                    isMonitoring = true
                    startForegroundService()
                }
            }
        }
        // 使用START_STICKY确保服务被系统杀死后自动重启
        return START_STICKY
    }
    
    private fun startForegroundService() {
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        ensureNotificationChannel()

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("枕边哨")
            .setContentText("正在后台监测你的姿势")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        // 使用通用前台服务启动方式，避免在部分机型/系统上因 HEALTH 类型权限导致崩溃或反复重启
        startForeground(NOTIFICATION_ID, notification)
    }
    
    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager = getSystemService(NotificationManager::class.java) ?: return
        val existing = notificationManager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "姿势监测服务",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "用于后台监测用户姿势"
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
        }
        notificationManager.createNotificationChannel(channel)
    }
    
    private fun startSensorListening() {
        accelerometer?.let {
            acquireWakeLock()
            // 根据前后台调整采样频率：前台使用NORMAL（约50Hz），后台使用UI（约15Hz）以节省电量
            val delay = if (isInForeground) {
                SensorManager.SENSOR_DELAY_NORMAL
            } else {
                SensorManager.SENSOR_DELAY_UI
            }
            sensorManager?.registerListener(this, it, delay)
        }
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        wakeLock?.let {
            it.setReferenceCounted(false)
            if (!it.isHeld) {
                // 使用10分钟超时，避免长时间持有
                it.acquire(10 * 60 * 1000L)
                // 启动续期机制
                startWakeLockRenewal()
            }
        }
    }
    
    // WakeLock续期机制：每5分钟续期一次
    private var wakeLockRenewalHandler: Handler? = null
    private var wakeLockRenewalRunnable: Runnable? = null
    
    private fun startWakeLockRenewal() {
        wakeLockRenewalHandler = Handler(Looper.getMainLooper())
        wakeLockRenewalRunnable = object : Runnable {
            override fun run() {
                wakeLock?.let {
                    if (it.isHeld && isMonitoring) {
                        // 续期10分钟
                        it.acquire(10 * 60 * 1000L)
                        android.util.Log.d("FloatingWindow", "WakeLock renewed")
                        // 5分钟后再次续期
                        wakeLockRenewalHandler?.postDelayed(this, 5 * 60 * 1000L)
                    }
                }
            }
        }
        // 5分钟后开始第一次续期
        wakeLockRenewalHandler?.postDelayed(wakeLockRenewalRunnable!!, 5 * 60 * 1000L)
    }
    
    private fun stopWakeLockRenewal() {
        wakeLockRenewalRunnable?.let {
            wakeLockRenewalHandler?.removeCallbacks(it)
        }
        wakeLockRenewalRunnable = null
    }

    private fun stopSensorListening() {
        sensorManager?.unregisterListener(this)
        stopWakeLockRenewal()
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
    }
    
    // 判断当前是否可以认为“用户在使用手机”（用于场景门控，减少误判）
    private fun isUserInteracting(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            val screenOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                pm.isInteractive
            } else {
                @Suppress("DEPRECATION")
                pm.isScreenOn
            }
            // 这里我们只用“屏幕亮且设备解锁”作为较弱的使用信号
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            val unlocked = !keyguardManager.isKeyguardLocked
            screenOn && unlocked
        } catch (e: Exception) {
            // 任何异常都不阻塞检测，默认为正在使用
            true
        }
    }

    /**
     * 将重力在设备坐标系下的 (nx, ny) 分量，根据当前显示旋转角度
     * 重映射到“屏幕坐标系”的左右(X) / 上下(Y)，以减少横屏时的误判。
     */
    private fun remapGravityToScreen(nx: Double, ny: Double): Pair<Double, Double> {
        return when (displayRotation) {
            Surface.ROTATION_0 -> Pair(nx, ny)
            Surface.ROTATION_90 -> Pair(-ny, nx)
            Surface.ROTATION_180 -> Pair(-nx, -ny)
            Surface.ROTATION_270 -> Pair(ny, -nx)
            else -> Pair(nx, ny)
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        try {
            if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER || !isMonitoring) return
            
            val ax = event.values[0].toDouble()
            val ay = event.values[1].toDouble()
            val az = event.values[2].toDouble()
            val g = sqrt(ax * ax + ay * ay + az * az)
            
            if (g < 1e-3) return
            
            val nx = ax / g
            val ny = ay / g
            val nz = az / g
            
            // 指数平滑
            val alpha = 0.15
            avgNx = alpha * nx + (1 - alpha) * avgNx
            avgNy = alpha * ny + (1 - alpha) * avgNy
            avgNz = alpha * nz + (1 - alpha) * avgNz
            
            // 场景门控：仅在认为“用户正在使用手机”时才进入姿势判定
            if (!isUserInteracting()) {
                // 如果之前处于侧躺状态，这里直接视为恢复正常
                if (isSideLying) {
                    isSideLying = false
                    sideLyingSince = null
                    sideCandidateSince = null
                    sideDetectionWindow.clear()
                    consecutiveSideCount = 0
                    consecutiveNormalCount = 0
                    sideHoldMs = 0L
                    normalHoldMs = 0L
                    mainHandler.post {
                        updateFloatingWindowState(false)
                    }
                    Companion.sendPostureEvent(false, null)
                } else {
                    // 清空候选计时，避免误触发
                    sideCandidateSince = null
                    sideDetectionWindow.clear()
                    consecutiveSideCount = 0
                    consecutiveNormalCount = 0
                    sideHoldMs = 0L
                    normalHoldMs = 0L
                }
                return
            }

            // 检测姿势变化（使用更宽松的阈值，避免误判）
            var deltaG = 0.0
            if (lastG != null) {
                deltaG = abs(g - lastG!!)
            }
            lastG = g
            
            // 只有在重力变化非常大时才重置（提高阈值，减少误判）
            // 0.8 -> 2.0，只有在剧烈运动时才重置
            if (deltaG > 2.0) {
                android.util.Log.d("FloatingWindow", "Large movement detected (deltaG=$deltaG), resetting detection")
                sideCandidateSince = null
                consecutiveSideCount = 0
                consecutiveNormalCount = 0
                sideDetectionWindow.clear()
                if (isSideLying) {
                    isSideLying = false
                    sideLyingSince = null
                    // 切换到主线程更新UI
                    mainHandler.post {
                        updateFloatingWindowState(false)
                    }
                    Companion.sendPostureEvent(false, null)
                }
                return
            }
            
            // 计算“竖直程度”：屏幕法线与重力方向之间的夹角（越大越竖直）
            val absNz = abs(avgNz)
            // tiltDeg = acos(|nz|)；这里直接用阈值对应的 cos 值，避免反三角运算
            val isUpright = absNz <= 0.766  // ≈ cos(40°)，代表屏幕与重力夹角在 40°~90° 之间

            // 将重力在设备坐标系下的 (avgNx, avgNy) 分量重映射到屏幕坐标系
            // 以减少横屏状态下的误判
            val (screenNx, screenNy) = remapGravityToScreen(avgNx, avgNy)
            val ratio = abs(screenNx) / (abs(screenNy) + 1e-3) // X/Y 比值，越大越接近“侧边朝下”

            // 使用自定义姿势时，仍然优先走自定义匹配
            val isSideCandidate = if (useCustomPostures && customPostures.isNotEmpty()) {
                // 使用自定义姿势检测
                val match = customPostures.minByOrNull { posture ->
                    posture.calculateSimilarity(avgNx, avgNy, avgNz, ax, ay, az)
                }
                // 如果相似度低于阈值（0.5），认为是匹配的姿势
                match?.let { it.calculateSimilarity(avgNx, avgNy, avgNz, ax, ay, az) < 0.5 } ?: false
            } else {
                // 使用默认系统算法：基于“屏幕够竖直 + 侧边朝下”的组合判断高风险侧躺姿势
                // 进入条件：屏幕相对竖直 + X/Y 比值较大（≈ roll 接近 ±90°）
                isUpright && ratio > 1.8
            }
            
            val now = System.currentTimeMillis()

            // 基于时间的稳定判定：按事件间隔累计“风险姿势停留时间”和“正常姿势时间”
            val dtMs = lastSampleTimeMs?.let { (now - it).coerceIn(0L, 500L) } ?: 0L
            lastSampleTimeMs = now

            if (isSideCandidate) {
                sideHoldMs += dtMs
                normalHoldMs = 0L
            } else {
                normalHoldMs += dtMs
                sideHoldMs = 0L
            }

            // 进入/退出稳定阈值（毫秒）
            val enterHoldMs = 1000L  // 大约 1 秒持续风险姿势才认为开始侧躺
            val exitHoldMs = 1500L   // 大约 1.5 秒持续正常姿势才认为退出侧躺

            if (!isSideLying && sideHoldMs >= enterHoldMs) {
                // 确认进入侧躺
                isSideLying = true
                sideLyingSince = now
                sideCandidateSince = now
                android.util.Log.d("FloatingWindow", "Side lying confirmed (hold=${sideHoldMs}ms), updating UI")
                // 通过EventChannel推送状态到Flutter
                Companion.sendPostureEvent(true, sideLyingSince)
                // 切换到主线程更新UI
                mainHandler.post {
                    // 确保悬浮窗存在
                    if (floatingView == null && isMonitoring) {
                        android.util.Log.w("FloatingWindow", "floatingView is null, recreating...")
                        showFloatingWindow()
                    }
                    updateFloatingWindowState(true)
                }
                // 防止溢出，进入后将累计时间截断到阈值
                sideHoldMs = enterHoldMs
            } else if (isSideLying && normalHoldMs >= exitHoldMs) {
                // 确认恢复正常姿势
                android.util.Log.d("FloatingWindow", "Normal posture confirmed (hold=${normalHoldMs}ms), resetting side lying state")
                sideCandidateSince = null
                isSideLying = false
                sideLyingSince = null
                // 通过EventChannel推送状态到Flutter
                Companion.sendPostureEvent(false, null)
                // 切换到主线程更新UI
                mainHandler.post {
                    updateFloatingWindowState(false)
                }
                // 防止溢出，退出后将累计时间截断到阈值
                normalHoldMs = exitHoldMs
            }
        } catch (e: Exception) {
            e.printStackTrace()
            // 捕获异常，防止服务崩溃
        }
    }
    
    private fun startReminderCheck() {
        try {
            reminderCheckRunnable = object : Runnable {
                override fun run() {
                    try {
                        if (isMonitoring && isSideLying && sideLyingSince != null) {
                            checkAndTriggerReminder()
                        }
                        reminderCheckHandler?.postDelayed(this, 1000) // 每秒检查一次
                    } catch (e: Exception) {
                        e.printStackTrace()
                        // 即使出错也继续运行
                        reminderCheckHandler?.postDelayed(this, 1000)
                    }
                }
            }
            reminderCheckHandler?.post(reminderCheckRunnable!!)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    private fun stopReminderCheck() {
        reminderCheckRunnable?.let {
            reminderCheckHandler?.removeCallbacks(it)
        }
        reminderCheckRunnable = null
    }
    
    private fun checkAndTriggerReminder() {
        try {
            val now = System.currentTimeMillis()

            // 必须已经确认是侧躺状态，并且有起始时间
            val start = sideLyingSince ?: return

            val thresholdSeconds = thresholdSecondsCache.coerceIn(1, 300)

            // 侧躺持续时间
            val elapsed = (now - start) / 1000
            if (elapsed < thresholdSeconds) {
                android.util.Log.d(
                    "FloatingWindow",
                    "Elapsed time $elapsed < threshold $thresholdSeconds (service, from prefs)"
                )
                return
            }

            if (dndEnabled && isInDnd(now, dndStartMinutes, dndEndMinutes)) {
                android.util.Log.d(
                    "FloatingWindow",
                    "Currently in DND window ($dndStartMinutes-$dndEndMinutes), skip reminder"
                )
                return
            }

            android.util.Log.d(
                "FloatingWindow",
                "Triggering reminder in service: elapsed=$elapsed, threshold=$thresholdSeconds (from prefs)"
            )

            // 重置计时起点，保证后续还能按周期继续提醒
            sideLyingSince = now

            // 震动提醒：尊重设置开关（在子线程执行，震动操作是线程安全的）
            if (vibrationEnabled) {
                try {
                    val hasVibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        vibrator?.hasVibrator() ?: false
                    } else {
                        @Suppress("DEPRECATION")
                        vibrator?.hasVibrator() ?: false
                    }

                    if (hasVibrator) {
                        val pattern = longArrayOf(0, 120, 60, 120)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, -1))
                        } else {
                            @Suppress("DEPRECATION")
                            vibrator?.vibrate(pattern, -1)
                        }
                        android.util.Log.d("FloatingWindow", "Vibration triggered from service")
                    } else {
                        android.util.Log.w("FloatingWindow", "Vibrator not available in service")
                    }
                } catch (e: Exception) {
                    android.util.Log.e("FloatingWindow", "Vibration error in service: ${e.message}", e)
                    e.printStackTrace()
                }
            } else {
                android.util.Log.d("FloatingWindow", "Vibration disabled, skip haptics")
            }

            // 更新统计（写入 SharedPreferences，在子线程执行，使用 apply() 异步写入）
            updateReminderCount()

            // 发送通知（需要切回主线程，因为 NotificationManager 可能需要在主线程操作）
            mainHandler.post {
                showReminderNotification()
            }
        } catch (e: Exception) {
            e.printStackTrace()
            // 捕获异常，防止服务崩溃
        }
    }
    
    private fun updateSettingsFromIntent(intent: Intent?) {
        intent ?: return
        if (intent.hasExtra(EXTRA_VIBRATION_ENABLED)) {
            vibrationEnabled = intent.getBooleanExtra(EXTRA_VIBRATION_ENABLED, vibrationEnabled)
        }
        if (intent.hasExtra(EXTRA_DND_START_MINUTES)) {
            dndStartMinutes = intent.getIntExtra(EXTRA_DND_START_MINUTES, dndStartMinutes)
        }
        if (intent.hasExtra(EXTRA_DND_END_MINUTES)) {
            dndEndMinutes = intent.getIntExtra(EXTRA_DND_END_MINUTES, dndEndMinutes)
        }
        if (intent.hasExtra(EXTRA_DND_ENABLED)) {
            dndEnabled = intent.getBooleanExtra(EXTRA_DND_ENABLED, dndEnabled)
        }
        
        // 更新自定义姿势数据
        if (intent.hasExtra("use_custom_postures")) {
            useCustomPostures = intent.getBooleanExtra("use_custom_postures", false)
            android.util.Log.d("FloatingWindow", "Use custom postures: $useCustomPostures")
        }
        if (intent.hasExtra("custom_postures_json")) {
            val posturesJson = intent.getStringExtra("custom_postures_json")
            if (posturesJson != null) {
                try {
                    customPostures.clear()
                    val jsonArray = org.json.JSONArray(posturesJson)
                    for (i in 0 until jsonArray.length()) {
                        val postureObj = jsonArray.getJSONObject(i)
                        customPostures.add(
                            CustomPostureData(
                                id = postureObj.getString("id"),
                                name = postureObj.getString("name"),
                                avgNx = postureObj.getDouble("avgNx"),
                                avgNy = postureObj.getDouble("avgNy"),
                                avgNz = postureObj.getDouble("avgNz"),
                                rawAx = postureObj.getDouble("rawAx"),
                                rawAy = postureObj.getDouble("rawAy"),
                                rawAz = postureObj.getDouble("rawAz")
                            )
                        )
                    }
                    android.util.Log.d("FloatingWindow", "Loaded ${customPostures.size} custom postures")
                } catch (e: Exception) {
                    android.util.Log.e("FloatingWindow", "Failed to parse custom postures: ${e.message}", e)
                }
            }
        }
        if (intent.hasExtra(EXTRA_THRESHOLD_SECONDS)) {
            thresholdSecondsCache = intent
                .getIntExtra(EXTRA_THRESHOLD_SECONDS, thresholdSecondsCache)
                .coerceIn(1, 300)
        }
        if (intent.hasExtra(EXTRA_MONITORING)) {
            val monitoring = intent.getBooleanExtra(EXTRA_MONITORING, isMonitoring)
            handleMonitoringToggleFromSettings(monitoring)
        }
        android.util.Log.d(
            "FloatingWindow",
            "Settings updated via broadcast: vibration=$vibrationEnabled, " +
                "threshold=$thresholdSecondsCache, dnd=$dndStartMinutes-$dndEndMinutes, dndEnabled=$dndEnabled"
        )
    }

    private fun handleMonitoringToggleFromSettings(enable: Boolean) {
        if (enable) {
            if (!isMonitoring) {
                isMonitoring = true
                startForegroundService()
                showFloatingWindow()
                startSensorListening()
                startReminderCheck()
            }
        } else if (isMonitoring) {
            isMonitoring = false
            stopSensorListening()
            stopReminderCheck()
            hideFloatingWindow()
            stopForeground(true)
            stopSelf()
        }
    }

    private fun loadSettingsFromPrefs() {
        val prefs = sharedPreferences ?: return
        vibrationEnabled = readBooleanPref(prefs, "flutter.vibration_enabled", true)
        thresholdSecondsCache = readIntPref(prefs, "flutter.threshold_seconds", 5).coerceIn(1, 300)
        dndStartMinutes = readIntPref(prefs, "flutter.dnd_start_minutes", 23 * 60)
        dndEndMinutes = readIntPref(prefs, "flutter.dnd_end_minutes", 7 * 60)
        dndEnabled = readBooleanPref(prefs, "flutter.dnd_enabled", false)
    }

    private fun readBooleanPref(
        prefs: SharedPreferences,
        key: String,
        defaultValue: Boolean
    ): Boolean {
        return try {
            prefs.getBoolean(key, defaultValue)
        } catch (e: ClassCastException) {
            defaultValue
        }
    }

    private fun readIntPref(
        prefs: SharedPreferences,
        key: String,
        defaultValue: Int
    ): Int {
        return try {
            prefs.getInt(key, defaultValue)
        } catch (e: ClassCastException) {
            val longValue = prefs.getLong(key, defaultValue.toLong())
            if (longValue > Int.MAX_VALUE) Int.MAX_VALUE else longValue.toInt()
        }
    }

    private fun isInDnd(now: Long, dndStartMinutes: Int, dndEndMinutes: Int): Boolean {
        val calendar = java.util.Calendar.getInstance()
        calendar.timeInMillis = now
        val currentMinutes = calendar.get(java.util.Calendar.HOUR_OF_DAY) * 60 + 
                            calendar.get(java.util.Calendar.MINUTE)
        
        return if (dndStartMinutes <= dndEndMinutes) {
            currentMinutes >= dndStartMinutes && currentMinutes < dndEndMinutes
        } else {
            currentMinutes >= dndStartMinutes || currentMinutes < dndEndMinutes
        }
    }
    
    private fun updateReminderCount() {
        try {
            val prefs = sharedPreferences ?: return
            val calendar = java.util.Calendar.getInstance()
            val todayKey = "${calendar.get(java.util.Calendar.YEAR)}-${calendar.get(java.util.Calendar.MONTH) + 1}-${calendar.get(java.util.Calendar.DAY_OF_MONTH)}"
            
            // Flutter SharedPreferences 实际以 "flutter." 前缀存储 key
            val storedDate = prefs.getString("flutter.today_date", null)
            val count = if (storedDate == todayKey) {
                try {
                    prefs.getInt("flutter.today_remind_count", 0)
                } catch (e: ClassCastException) {
                    // 兼容旧版本可能以 Long 存储的情况
                    val longVal = prefs.getLong("flutter.today_remind_count", 0L)
                    if (longVal > Int.MAX_VALUE) Int.MAX_VALUE else longVal.toInt()
                }
            } else {
                0
            }

            val newCount = count + 1
            
            // 通过EventChannel推送统计数据到Flutter
            Companion.sendStatsEvent(newCount)
            
            // 使用 apply() 异步写入，避免阻塞当前线程（已在子线程中）
            prefs.edit()
                .putString("flutter.today_date", todayKey)
                .putInt("flutter.today_remind_count", newCount)
                .apply() // apply() 是异步的，不会阻塞
            
            android.util.Log.d("FloatingWindow", "Reminder count updated: $newCount (date: $todayKey)")
        } catch (e: Exception) {
            android.util.Log.e("FloatingWindow", "Error updating reminder count: ${e.message}", e)
            e.printStackTrace()
        }
    }
    
    private fun showReminderNotification() {
        try {
            val notificationIntent = Intent(this, MainActivity::class.java)
            val pendingIntent = PendingIntent.getActivity(
                this, 0, notificationIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            
            ensureNotificationChannel()

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("姿势不对哦～")
                .setContentText("你可能正在侧躺玩手机，注意颈椎健康哦～")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.notify(1002, notification)
        } catch (e: Exception) {
            e.printStackTrace()
            // 通知失败不影响服务运行
        }
    }
    
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // 不需要处理
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showFloatingWindow() {
        try {
            // 如果悬浮窗已存在，先检查是否真的在WindowManager中
            if (floatingView != null) {
                // 检查悬浮窗是否还在WindowManager中
                try {
                    windowManager?.updateViewLayout(floatingView, windowParams)
                    android.util.Log.d("FloatingWindow", "Floating window already exists and is valid")
                    return
                } catch (e: Exception) {
                    // 如果更新失败，说明悬浮窗已丢失，需要重新创建
                    android.util.Log.w("FloatingWindow", "Floating window lost, recreating...")
                    floatingView = null
                    windowParams = null
                }
            }

            android.util.Log.d("FloatingWindow", "Creating new floating window")
            val inflater = LayoutInflater.from(this)
            floatingView = inflater.inflate(R.layout.floating_window, null)

        windowParams = WindowManager.LayoutParams(
            200, // width
            200, // height
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            // 默认位置改为右上角
            gravity = Gravity.TOP or Gravity.END
            x = 0
            y = 200
        }

        val floatingButton = floatingView?.findViewById<ImageView>(R.id.floating_button)
        val floatingText = floatingView?.findViewById<TextView>(R.id.floating_text)

        // 设置初始状态
        updateFloatingWindowState(isSideLying)

        // 拖动功能
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f

        floatingView?.setOnTouchListener { view, event ->
            val params = windowParams ?: return@setOnTouchListener false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params.x
                    initialY = params.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = initialX + (event.rawX - initialTouchX).toInt()
                    params.y = initialY + (event.rawY - initialTouchY).toInt()
                    windowManager?.updateViewLayout(floatingView, params)
                    true
                }
                MotionEvent.ACTION_UP -> {
                    // 点击事件
                    if (kotlin.math.abs(event.rawX - initialTouchX) < 10 &&
                        kotlin.math.abs(event.rawY - initialTouchY) < 10) {
                        // 点击悬浮窗，可以打开应用
                        val intent = packageManager.getLaunchIntentForPackage(packageName)
                        intent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                    }
                    true
                }
                else -> false
            }
        }

            try {
                windowManager?.addView(floatingView, windowParams)
                android.util.Log.d("FloatingWindow", "Floating window added successfully")
            } catch (e: Exception) {
                android.util.Log.e("FloatingWindow", "Error adding floating window: ${e.message}", e)
                e.printStackTrace()
                // 如果添加失败，清理资源
                floatingView = null
                windowParams = null
            }
        } catch (e: Exception) {
            android.util.Log.e("FloatingWindow", "Error in showFloatingWindow: ${e.message}", e)
            e.printStackTrace()
            // 捕获所有异常，防止服务崩溃
            floatingView = null
            windowParams = null
        }
    }

    private fun hideFloatingWindow() {
        floatingView?.let {
            try {
                windowManager?.removeView(it)
            } catch (e: Exception) {
                e.printStackTrace()
            }
            floatingView = null
            windowParams = null
        }
    }

    private fun updateFloatingWindowState(sideLying: Boolean) {
        try {
            // 确保在主线程执行
            if (Looper.myLooper() != Looper.getMainLooper()) {
                mainHandler.post {
                    updateFloatingWindowState(sideLying)
                }
                return
            }
            
            isSideLying = sideLying
            
            // 检查悬浮窗是否存在
            if (floatingView == null) {
                android.util.Log.e("FloatingWindow", "floatingView is null when updating state, recreating...")
                // 如果悬浮窗丢失，尝试重新创建
                if (isMonitoring) {
                    showFloatingWindow()
                }
                return
            }
            
            val floatingButton = floatingView?.findViewById<ImageView>(R.id.floating_button)
            val floatingText = floatingView?.findViewById<TextView>(R.id.floating_text)

            if (floatingButton == null || floatingText == null) {
                android.util.Log.e("FloatingWindow", "floatingButton or floatingText is null, recreating floating window...")
                // 如果UI组件丢失，重新创建悬浮窗
                hideFloatingWindow()
                if (isMonitoring) {
                    showFloatingWindow()
                }
                return
            }

            try {
                if (sideLying) {
                    android.util.Log.d("FloatingWindow", "Updating to side lying state (icon)")
                    floatingButton.setImageResource(R.drawable.ic_monitor_alert)
                    floatingText.text = "侧躺中"
                    floatingText.setTextColor(
                        ContextCompat.getColor(this, android.R.color.holo_purple)
                    )
                } else {
                    android.util.Log.d("FloatingWindow", "Updating to normal state (icon)")
                    floatingButton.setImageResource(R.drawable.ic_monitor_normal)
                    floatingText.text = "监测中"
                    floatingText.setTextColor(
                        ContextCompat.getColor(this, android.R.color.holo_green_dark)
                    )
                }
            } catch (e: Exception) {
                android.util.Log.e("FloatingWindow", "Error updating UI: ${e.message}", e)
                e.printStackTrace()
                // 如果UI更新失败，尝试重新创建悬浮窗
                if (isMonitoring) {
                    android.util.Log.w("FloatingWindow", "UI update failed, recreating floating window")
                    hideFloatingWindow()
                    mainHandler.postDelayed({
                        if (isMonitoring) {
                            showFloatingWindow()
                        }
                    }, 100)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("FloatingWindow", "Error in updateFloatingWindowState: ${e.message}", e)
            e.printStackTrace()
            // 捕获异常，防止服务崩溃
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            stopSensorListening()
            stopReminderCheck()
            reminderThread?.quitSafely()
            reminderThread = null
            hideFloatingWindow()
            try {
                unregisterReceiver(settingsReceiver)
            } catch (e: Exception) {
                android.util.Log.w("FloatingWindow", "Receiver already unregistered: ${e.message}")
            }
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            // 清理EventChannel
            Companion.setEventSink(null)
        } catch (e: Exception) {
            android.util.Log.e("FloatingWindow", "Error in onDestroy: ${e.message}", e)
        }
    }

}

