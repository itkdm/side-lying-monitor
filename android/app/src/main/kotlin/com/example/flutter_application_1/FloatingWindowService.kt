package com.example.flutter_application_1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.PixelFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
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
import android.widget.ImageView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.sqrt

class FloatingWindowService : Service(), SensorEventListener {
    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var windowParams: WindowManager.LayoutParams? = null
    private var isSideLying = false
    
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
    
    // 提醒相关
    private var reminderCheckHandler: Handler? = null
    private var reminderCheckRunnable: Runnable? = null
    private var vibrator: Vibrator? = null
    private var sharedPreferences: SharedPreferences? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
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
        
        // 创建Handler用于定时检查提醒
        reminderCheckHandler = Handler(Looper.getMainLooper())
        
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW -> {
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
                isMonitoring = false
                stopSensorListening()
                stopReminderCheck()
                hideFloatingWindow()
                stopForeground(true)
                stopSelf()
            }
            ACTION_UPDATE_STATE -> {
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
            // 使用超时WakeLock，每10分钟自动续期
            wakeLock?.acquire(10*60*1000L /*10 minutes*/)
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }
    
    // 定期续期WakeLock
    private fun renewWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
            it.acquire(10*60*1000L)
        }
    }
    
    private fun stopSensorListening() {
        sensorManager?.unregisterListener(this)
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
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
            
            // 检测姿势变化
            var deltaG = 0.0
            if (lastG != null) {
                deltaG = abs(g - lastG!!)
            }
            lastG = g
            
            if (deltaG > 0.8) {
                sideCandidateSince = null
                if (isSideLying) {
                    isSideLying = false
                    sideLyingSince = null
                    // 切换到主线程更新UI
                    Handler(Looper.getMainLooper()).post {
                        updateFloatingWindowState(false)
                    }
                }
                return
            }
            
            // 判断是否侧躺
            val isScreenRoughlyVertical = abs(avgNz) < 0.8
            val isGravityMostlySide = abs(avgNx) > 0.4 || abs(avgNy) > 0.4
            val isSideByDirection = isScreenRoughlyVertical && isGravityMostlySide
            val isSideByRaw = abs(ax) > 6.5 && abs(az) < 5.0
            val isSide = isSideByDirection || isSideByRaw
            
            val now = System.currentTimeMillis()
            
            if (isSide) {
                sideCandidateSince = sideCandidateSince ?: now
                val stableDuration = (now - sideCandidateSince!!) / 1000
                val stableThresholdSeconds = 2
                
                if (!isSideLying && stableDuration >= stableThresholdSeconds) {
                    isSideLying = true
                    sideLyingSince = now
                    android.util.Log.d("FloatingWindow", "Side lying detected, updating UI")
                    // 切换到主线程更新UI
                    Handler(Looper.getMainLooper()).post {
                        // 确保悬浮窗存在
                        if (floatingView == null && isMonitoring) {
                            android.util.Log.w("FloatingWindow", "floatingView is null, recreating...")
                            showFloatingWindow()
                        }
                        updateFloatingWindowState(true)
                    }
                }
            } else {
                sideCandidateSince = null
                if (isSideLying) {
                    isSideLying = false
                    sideLyingSince = null
                    // 切换到主线程更新UI
                    Handler(Looper.getMainLooper()).post {
                        updateFloatingWindowState(false)
                    }
                }
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

            // 从 SharedPreferences 读取阈值（优先 flutter.threshold_seconds），读取失败或类型不匹配则回退到 5 秒
            val prefs = sharedPreferences
            val thresholdSeconds = try {
                if (prefs != null) {
                    when {
                        prefs.contains("flutter.threshold_seconds") -> {
                            try {
                                prefs.getInt("flutter.threshold_seconds", 5)
                            } catch (e: ClassCastException) {
                                // 兼容旧版本可能以 Long 存储的情况
                                val longVal = prefs.getLong("flutter.threshold_seconds", 5L)
                                if (longVal > Int.MAX_VALUE) Int.MAX_VALUE else longVal.toInt()
                            }
                        }
                        prefs.contains("threshold_seconds") -> {
                            try {
                                prefs.getInt("threshold_seconds", 5)
                            } catch (e: ClassCastException) {
                                val longVal = prefs.getLong("threshold_seconds", 5L)
                                if (longVal > Int.MAX_VALUE) Int.MAX_VALUE else longVal.toInt()
                            }
                        }
                        else -> 5
                    }.coerceIn(1, 300)
                } else {
                    5
                }
            } catch (e: Exception) {
                android.util.Log.e("FloatingWindow", "Error reading threshold from prefs, fallback to 5", e)
                5
            }

            // 侧躺持续时间
            val elapsed = (now - start) / 1000
            if (elapsed < thresholdSeconds) {
                android.util.Log.d(
                    "FloatingWindow",
                    "Elapsed time $elapsed < threshold $thresholdSeconds (service, from prefs)"
                )
                return
            }

            android.util.Log.d(
                "FloatingWindow",
                "Triggering reminder in service: elapsed=$elapsed, threshold=$thresholdSeconds (from prefs)"
            )

            // 重置计时起点，保证后续还能按周期继续提醒
            sideLyingSince = now

            // 震动提醒：在悬浮窗模式下，始终尝试震动
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

            // 更新统计（写入 SharedPreferences，供 Flutter 端读取）
            updateReminderCount()

            // 发送通知
            showReminderNotification()
        } catch (e: Exception) {
            e.printStackTrace()
            // 捕获异常，防止服务崩溃
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

            android.util.Log.d(
                "FloatingWindow",
                "Current stored reminder prefs: date=$storedDate, count=$count, todayKey=$todayKey"
            )
            
            val newCount = count + 1
            android.util.Log.d("FloatingWindow", "Updating reminder count: $count -> $newCount (date: $todayKey)")
            
            prefs.edit()
                .putString("flutter.today_date", todayKey)
                .putInt("flutter.today_remind_count", newCount)
                .apply()
            
            android.util.Log.d("FloatingWindow", "Reminder count updated successfully")
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
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
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
                Handler(Looper.getMainLooper()).post {
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
                    // 侧躺状态：紫色，睡眠图标
                    android.util.Log.d("FloatingWindow", "Updating to side lying state (purple)")
                    floatingButton.setImageResource(android.R.drawable.ic_menu_revert)
                    floatingButton.setColorFilter(
                        ContextCompat.getColor(this, android.R.color.holo_purple),
                        android.graphics.PorterDuff.Mode.SRC_IN
                    )
                    floatingText.text = "侧躺中"
                    floatingText.setTextColor(
                        ContextCompat.getColor(this, android.R.color.holo_purple)
                    )
                    android.util.Log.d("FloatingWindow", "Successfully updated to side lying state")
                } else {
                    // 正常状态：绿色，星星图标
                    android.util.Log.d("FloatingWindow", "Updating to normal state (green)")
                    floatingButton.setImageResource(android.R.drawable.btn_star_big_on)
                    floatingButton.setColorFilter(
                        ContextCompat.getColor(this, android.R.color.holo_green_dark),
                        android.graphics.PorterDuff.Mode.SRC_IN
                    )
                    floatingText.text = "监测中"
                    floatingText.setTextColor(
                        ContextCompat.getColor(this, android.R.color.holo_green_dark)
                    )
                    android.util.Log.d("FloatingWindow", "Successfully updated to normal state")
                }
            } catch (e: Exception) {
                android.util.Log.e("FloatingWindow", "Error updating UI: ${e.message}", e)
                e.printStackTrace()
                // 如果UI更新失败，尝试重新创建悬浮窗
                if (isMonitoring) {
                    android.util.Log.w("FloatingWindow", "UI update failed, recreating floating window")
                    hideFloatingWindow()
                    Handler(Looper.getMainLooper()).postDelayed({
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
        stopSensorListening()
        stopReminderCheck()
        hideFloatingWindow()
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
    }

    companion object {
        const val ACTION_SHOW = "com.example.flutter_application_1.SHOW_FLOATING_WINDOW"
        const val ACTION_HIDE = "com.example.flutter_application_1.HIDE_FLOATING_WINDOW"
        const val ACTION_UPDATE_STATE = "com.example.flutter_application_1.UPDATE_STATE"
        const val EXTRA_IS_SIDE_LYING = "is_side_lying"
        private const val CHANNEL_ID = "floating_window_service_channel"
        private const val NOTIFICATION_ID = 1001
    }
}

