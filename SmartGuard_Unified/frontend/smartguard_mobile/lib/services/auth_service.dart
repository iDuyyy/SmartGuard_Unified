import 'package:local_auth/local_auth.dart';
import '../core/api_client.dart';
import '../core/session_manager.dart';
import '../models/models.dart';

class AuthService {
  static final LocalAuthentication _localAuth = LocalAuthentication();

  static Future<Map<String, dynamic>> register({
    required String email,
    required String username,
    required String password,
    String role = 'Owner',
  }) async {
    final response = await ApiClient.request('POST', '/api/auth/register', body: {
      'email': email,
      'username': username,
      'password': password,
      'role': role,
    });
    return response as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> login({
    required String identifier,
    required String password,
  }) async {
    final response = await ApiClient.request('POST', '/api/auth/login', body: {
      'identifier': identifier,
      'password': password,
    });
    return response as Map<String, dynamic>;
  }

  static Future<UserModel> verifyOtp({
    required String challengeId,
    required String code,
  }) async {
    final response = await ApiClient.request('POST', '/api/auth/verify-otp', body: {
      'challengeId': challengeId,
      'code': code,
    }) as Map<String, dynamic>;

    final token = response['token']?.toString() ?? '';

    final userMap = response['user'] is Map<String, dynamic>
        ? response['user'] as Map<String, dynamic>
        : response;

    final userId = userMap['id']?.toString() ??
        userMap['userId']?.toString() ??
        response['userId']?.toString() ??
        '';
    final email = userMap['email']?.toString() ??
        response['email']?.toString() ??
        '';
    final username = userMap['username']?.toString() ??
        response['username']?.toString() ??
        '';
    final role = userMap['role']?.toString() ??
        response['role']?.toString() ??
        'Owner';

    final finalUsername = username.isNotEmpty
        ? username
        : (email.isNotEmpty ? email.split('@').first : 'User');

    final user = UserModel(
      id: userId,
      email: email,
      username: finalUsername,
      role: role,
    );

    await SessionManager.saveSession(token, user);

    return user;
  }

  static Future<bool> canUseBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      final biometrics = await _localAuth.getAvailableBiometrics();
      return (canCheck || isDeviceSupported) && (biometrics.isNotEmpty || canCheck || isDeviceSupported);
    } catch (_) {
      return false;
    }
  }

  static bool _bioInProgress = false;

  /// Quét vân tay / Face ID. Trả về kết quả kèm lý do lỗi (không nuốt lỗi nữa).
  /// Chặn gọi chồng 2 lần (ví dụ tự bật khi mở màn hình + người dùng bấm nút).
  static Future<BiometricAuthResult> authenticateBiometric({
    String reason = 'Vui lòng quét vân tay hoặc khuôn mặt để mở khóa SmartGuard',
  }) async {
    if (_bioInProgress) {
      return const BiometricAuthResult(false, busy: true);
    }
    _bioInProgress = true;
    try {
      final ok = await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      return BiometricAuthResult(ok, message: ok ? null : 'Bạn đã hủy xác thực.');
    } catch (e) {
      return BiometricAuthResult(false, message: _describeBiometricError(e));
    } finally {
      _bioInProgress = false;
    }
  }

  static String _describeBiometricError(Object e) {
    final raw = e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('cancel') || lower.contains('usercanceled') || lower.contains('systemcanceled')) {
      return 'Bạn đã hủy xác thực.';
    }
    if (lower.contains('nocredentialsset') || lower.contains('notenrolled') || lower.contains('nobiometricsenrolled') || lower.contains('passcodenotset')) {
      return 'Thiết bị chưa đăng ký vân tay / khóa màn hình. Hãy thêm trong Cài đặt Android.';
    }
    if (lower.contains('lockedout') || lower.contains('temporarylockout') || lower.contains('biometriclockout')) {
      return 'Vân tay bị khóa tạm thời do thử sai nhiều lần. Hãy mở khóa máy bằng mã PIN rồi thử lại.';
    }
    if (lower.contains('fragmentactivity') || lower.contains('uiunavailable') || lower.contains('no_fragment_activity')) {
      return 'Lỗi cấu hình Android: MainActivity phải kế thừa FlutterFragmentActivity.';
    }
    if (lower.contains('authinprogress')) {
      return 'Đang có một yêu cầu xác thực khác, vui lòng thử lại.';
    }
    return 'Lỗi sinh trắc học: $raw';
  }

  /// Đăng xuất thông thường: xóa phiên hiện tại, GIỮ liên kết vân tay.
  static Future<void> logout() async {
    await SessionManager.clearSession();
  }

  /// Tắt đăng nhập vân tay: xóa hẳn tài khoản + token đã liên kết trên máy.
  static Future<void> unlinkBiometric() async {
    await SessionManager.removeBiometricBinding();
  }
}

class BiometricAuthResult {
  final bool success;
  final bool busy;
  final String? message;
  const BiometricAuthResult(this.success, {this.busy = false, this.message});
}
