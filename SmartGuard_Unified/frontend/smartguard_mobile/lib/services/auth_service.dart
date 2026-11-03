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
    final userId = response['userId']?.toString() ?? '';
    final email = response['email']?.toString() ?? '';
    final username = response['username']?.toString() ?? '';
    final role = response['role']?.toString() ?? 'Owner';

    final user = UserModel(
      id: userId,
      email: email,
      username: username,
      role: role,
    );

    await SessionManager.saveSession(token, user);

    return user;
  }

  static Future<bool> canUseBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return canCheck && isDeviceSupported;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticateBiometric() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Vui lòng quét vân tay hoặc khuôn mặt để mở khóa SmartGuard',
      );
    } catch (_) {
      return false;
    }
  }

  static Future<void> logout() async {
    await SessionManager.clearSession();
  }
}
