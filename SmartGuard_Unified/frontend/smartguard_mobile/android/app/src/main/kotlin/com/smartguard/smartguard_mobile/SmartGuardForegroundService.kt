package com.smartguard.smartguard_mobile

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * SmartGuard Foreground Service – Phase 2
 *
 * Giữ cho dịch vụ bảo vệ camera chạy bền bỉ ở tầng nền ngay cả khi:
 *  - Người dùng rời màn hình ứng dụng
 *  - Điện thoại tắt màn hình (Doze Mode / Battery Optimization)
 *  - Ứng dụng bị Android kill do thiếu RAM (sẽ tự khởi động lại qua START_STICKY)
 *
 * Foreground Type: camera + microphone
 * Notification channel: HIGH priority để không bị Android gộp/ẩn
 */
class SmartGuardForegroundService : Service() {

    companion object {
        const val TAG = "SmartGuardFS"
        const val CHANNEL_ID = "smartguard_guard_channel"
        const val CHANNEL_NAME = "Dịch vụ bảo vệ SmartGuard"
        const val NOTIF_ID = 10001
        const val ACTION_START = "com.smartguard.START_GUARD"
        const val ACTION_STOP = "com.smartguard.STOP_GUARD"
        const val ACTION_ALARM = "com.smartguard.ALARM_TRIGGERED"
        const val FLUTTER_CHANNEL = "com.smartguard/foreground"

        fun startService(context: Context) {
            val intent = Intent(context, SmartGuardForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, SmartGuardForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var isGuardActive = false

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "SmartGuard Foreground Service khởi tạo.")
        createNotificationChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Dừng SmartGuard Guard Service theo yêu cầu.")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ALARM -> {
                // Cập nhật notification khi có báo động
                updateNotificationAlarm()
            }
            else -> {
                // ACTION_START hoặc null → Khởi động
                isGuardActive = true
                startForeground(NOTIF_ID, buildGuardNotification())
                Log.i(TAG, "SmartGuard đang canh gác ở tầng nền... 🛡️")
            }
        }
        // START_STICKY: Android sẽ restart service nếu bị kill
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
        Log.w(TAG, "SmartGuard Service bị dừng – sẽ tự khởi động lại qua Boot Receiver.")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Tự restart khi người dùng xoá app khỏi recent tasks
        val restartIntent = Intent(applicationContext, SmartGuardForegroundService::class.java).apply {
            action = ACTION_START
        }
        val pendingIntent = PendingIntent.getService(
            applicationContext,
            1,
            restartIntent,
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
        )
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.set(
            AlarmManager.ELAPSED_REALTIME,
            android.os.SystemClock.elapsedRealtime() + 2000L,
            pendingIntent
        )
        Log.w(TAG, "onTaskRemoved – đã lên lịch khởi động lại sau 2 giây.")
    }

    // ═══ Private Helpers ═══

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Capybara Security Guard đang canh gác ngôi nhà của bạn 🐾"
                enableLights(true)
                lightColor = Color.parseColor("#FF6B4A")
                enableVibration(false)
                setShowBadge(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildGuardNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SmartGuard đang bảo vệ 🛡️")
            .setContentText("Capybara đang canh gác ngôi nhà của bạn. Chạm để mở ứng dụng.")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setColor(Color.parseColor("#FF6B4A"))
            .setShowWhen(false)
            .build()
    }

    private fun updateNotificationAlarm() {
        val notifManager = getSystemService(NotificationManager::class.java)
        val alarmNotif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("🚨 CẢNH BÁO XÂM NHẬP!")
            .setContentText("SmartGuard phát hiện chuyển động bất thường. Nhấn để xem camera.")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setColor(Color.RED)
            .setAutoCancel(false)
            .build()
        notifManager.notify(NOTIF_ID, alarmNotif)
    }

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "SmartGuard::GuardWakeLock"
        ).also {
            // 8 giờ tối đa – sẽ được release thủ công khi service dừng
            it.acquire(8 * 60 * 60 * 1000L)
        }
        Log.d(TAG, "WakeLock acquired – CPU sẽ không sleep trong lúc canh gác.")
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi release WakeLock: ${e.message}")
        }
    }
}

