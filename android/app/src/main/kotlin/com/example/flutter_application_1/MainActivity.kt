package com.example.flutter_application_1

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.flutter_application_1/floating_window"
    private val EVENT_CHANNEL = "com.example.flutter_application_1/posture_events"
    private val REQUEST_CODE_OVERLAY_PERMISSION = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 设置EventChannel用于推送姿态状态和统计数据
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    FloatingWindowService.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    FloatingWindowService.setEventSink(null)
                }
            }
        )
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkOverlayPermission" -> {
                    result.success(checkOverlayPermission())
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission()
                    result.success(null)
                }
                "showFloatingWindow" -> {
                    if (checkOverlayPermission()) {
                        showFloatingWindow()
                        result.success(true)
                    } else {
                        result.error("PERMISSION_DENIED", "悬浮窗权限未授予", null)
                    }
                }
                "hideFloatingWindow" -> {
                    hideFloatingWindow()
                    result.success(true)
                }
                "updateFloatingWindowState" -> {
                    val isSideLying = call.argument<Boolean>("isSideLying") ?: false
                    updateFloatingWindowState(isSideLying)
                    result.success(true)
                }
                "syncSettings" -> {
                    syncSettingsToService(
                        monitoring = call.argument<Boolean>("monitoring") ?: true,
                        vibrationEnabled = call.argument<Boolean>("vibrationEnabled") ?: true,
                        thresholdSeconds = call.argument<Int>("thresholdSeconds") ?: 5,
                        dndStartMinutes = call.argument<Int>("dndStartMinutes") ?: (23 * 60),
                        dndEndMinutes = call.argument<Int>("dndEndMinutes") ?: (7 * 60),
                        dndEnabled = call.argument<Boolean>("dndEnabled") ?: false
                    )
                    result.success(true)
                }
                "syncCustomPostures" -> {
                    val useCustomPostures = call.argument<Boolean>("useCustomPostures") ?: false
                    @Suppress("UNCHECKED_CAST")
                    val posturesList = call.argument<List<Map<String, Any>>>("customPostures") ?: emptyList()
                    syncCustomPosturesToService(useCustomPostures, posturesList)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun checkOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivityForResult(intent, REQUEST_CODE_OVERLAY_PERMISSION)
            }
        }
    }

    private fun showFloatingWindow() {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_SHOW
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun hideFloatingWindow() {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_HIDE
        }
        // 使用与 showFloatingWindow 相同的启动方式，只发送 ACTION_HIDE，
        // 由服务内部决定仅隐藏悬浮窗，不停止前台服务和监测。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun updateFloatingWindowState(isSideLying: Boolean) {
        val intent = Intent(this, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_UPDATE_STATE
            putExtra(FloatingWindowService.EXTRA_IS_SIDE_LYING, isSideLying)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }


    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_OVERLAY_PERMISSION) {
            // 权限请求结果，可以通过MethodChannel通知Flutter
        }
    }

    private fun syncSettingsToService(
        monitoring: Boolean,
        vibrationEnabled: Boolean,
        thresholdSeconds: Int,
        dndStartMinutes: Int,
        dndEndMinutes: Int,
        dndEnabled: Boolean
    ) {
        val intent = Intent(FloatingWindowService.ACTION_SETTINGS_UPDATED).apply {
            putExtra(FloatingWindowService.EXTRA_MONITORING, monitoring)
            putExtra(FloatingWindowService.EXTRA_VIBRATION_ENABLED, vibrationEnabled)
            putExtra(FloatingWindowService.EXTRA_THRESHOLD_SECONDS, thresholdSeconds)
            putExtra(FloatingWindowService.EXTRA_DND_START_MINUTES, dndStartMinutes)
            putExtra(FloatingWindowService.EXTRA_DND_END_MINUTES, dndEndMinutes)
            putExtra(FloatingWindowService.EXTRA_DND_ENABLED, dndEnabled)
        }
        sendBroadcast(intent)
    }
    
    private fun syncCustomPosturesToService(
        useCustomPostures: Boolean,
        posturesList: List<Map<String, Any>>
    ) {
        // 将自定义姿势数据传递给服务（通过Intent）
        val intent = Intent(FloatingWindowService.ACTION_SETTINGS_UPDATED).apply {
            putExtra("use_custom_postures", useCustomPostures)
            // 将姿势列表序列化为JSON字符串传递
            val jsonArray = org.json.JSONArray()
            posturesList.forEach { posture ->
                val postureObj = org.json.JSONObject().apply {
                    put("id", posture["id"] as? String ?: "")
                    put("name", posture["name"] as? String ?: "")
                    put("avgNx", (posture["avgNx"] as? Number)?.toDouble() ?: 0.0)
                    put("avgNy", (posture["avgNy"] as? Number)?.toDouble() ?: 0.0)
                    put("avgNz", (posture["avgNz"] as? Number)?.toDouble() ?: 0.0)
                    put("rawAx", (posture["rawAx"] as? Number)?.toDouble() ?: 0.0)
                    put("rawAy", (posture["rawAy"] as? Number)?.toDouble() ?: 0.0)
                    put("rawAz", (posture["rawAz"] as? Number)?.toDouble() ?: 0.0)
                }
                jsonArray.put(postureObj)
            }
            putExtra("custom_postures_json", jsonArray.toString())
        }
        sendBroadcast(intent)
    }
}
