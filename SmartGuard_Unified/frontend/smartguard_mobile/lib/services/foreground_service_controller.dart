import 'package:flutter/services.dart';

/// ForegroundServiceController — cầu nối Flutter ↔ Android Native
/// Gọi MethodChannel [com.smartguard/foreground] và [com.smartguard/phone]
/// để khởi động/dừng Foreground Service và thực hiện cuộc gọi khẩn cấp.
class ForegroundServiceController {
  static const MethodChannel _foregroundChannel =
      MethodChannel('com.smartguard/foreground');
  static const MethodChannel _phoneChannel =
      MethodChannel('com.smartguard/phone');
  static const MethodChannel _permissionsChannel =
      MethodChannel('com.smartguard/permissions');

  // ─── Foreground Service ────────────────────────────────────────────────────

  /// Khởi động SmartGuard Foreground Service
  static Future<bool> startService() async {
    try {
      final result = await _foregroundChannel.invokeMethod<bool>('startService');
      return result == true;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[ForegroundService] startService error: ${e.message}');
      return false;
    }
  }

  /// Dừng SmartGuard Foreground Service
  static Future<bool> stopService() async {
    try {
      final result = await _foregroundChannel.invokeMethod<bool>('stopService');
      return result == true;
    } on PlatformException catch (e) {
      print('[ForegroundService] stopService error: ${e.message}');
      return false;
    }
  }

  /// Cập nhật thông báo báo động trong Foreground Service
  static Future<void> notifyAlarm({
    required String title,
    required String message,
  }) async {
    try {
      await _foregroundChannel.invokeMethod('notifyAlarm', {
        'title': title,
        'message': message,
      });
    } on PlatformException catch (e) {
      print('[ForegroundService] notifyAlarm error: ${e.message}');
    }
  }

  // ─── Phone / Emergency Call ────────────────────────────────────────────────

  /// Gọi điện khẩn cấp đến số [phoneNumber]
  static Future<bool> callEmergency(String phoneNumber) async {
    try {
      // Làm sạch số điện thoại (chỉ giữ số và dấu +)
      final cleanNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
      final result = await _phoneChannel.invokeMethod<bool>(
        'callEmergency',
        {'phoneNumber': cleanNumber},
      );
      return result == true;
    } on PlatformException catch (e) {
      print('[Phone] callEmergency error: ${e.message}');
      return false;
    }
  }

  /// Kiểm tra quyền CALL_PHONE
  static Future<bool> checkCallPermission() async {
    try {
      final result =
          await _phoneChannel.invokeMethod<bool>('checkCallPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Yêu cầu quyền CALL_PHONE từ hệ thống
  static Future<bool> requestCallPermission() async {
    try {
      final result =
          await _phoneChannel.invokeMethod<bool>('requestCallPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  // ─── All Permissions ───────────────────────────────────────────────────────

  /// Yêu cầu tất cả quyền cần thiết (camera, mic, phone, notification)
  static Future<void> requestAllGuardPermissions() async {
    try {
      await _permissionsChannel.invokeMethod('requestAllGuardPermissions');
    } on PlatformException catch (e) {
      print('[Permissions] requestAll error: ${e.message}');
    }
  }

  /// Kiểm tra quyền thông báo (Android 13+)
  static Future<bool> checkNotificationPermission() async {
    try {
      final result = await _permissionsChannel
          .invokeMethod<bool>('checkNotificationPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  // ─── Battery Optimization (Doze Mode) ──────────────────────────────────────

  /// true nếu SmartGuard đã được miễn tối ưu pin → Doze không thể tắt service.
  /// Trên nền tảng không phải Android luôn trả về true.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result = await _permissionsChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Mở hộp thoại hệ thống xin miễn tối ưu pin.
  /// Kết quả thực tế cần kiểm tra lại bằng [isIgnoringBatteryOptimizations]
  /// sau khi người dùng quay lại ứng dụng (AppLifecycleState.resumed).
  static Future<bool> requestBatteryExemption() async {
    try {
      final result =
          await _permissionsChannel.invokeMethod<bool>('requestBatteryExemption');
      return result == true;
    } on PlatformException catch (e) {
      print('[Battery] requestBatteryExemption error: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Mở trang cài đặt danh sách tối ưu pin (dự phòng)
  static Future<bool> openBatterySettings() async {
    try {
      final result =
          await _permissionsChannel.invokeMethod<bool>('openBatterySettings');
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

