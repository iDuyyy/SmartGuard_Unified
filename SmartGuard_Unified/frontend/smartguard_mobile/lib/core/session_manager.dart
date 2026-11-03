import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class SessionManager {
  static const _secureStorage = FlutterSecureStorage();
  static const String _keyToken = 'sg_jwt_token';
  static const String _keyUser = 'sg_user_info';
  static const String _keyBiometricEnabled = 'sg_biometric_enabled';

  // Lưu trữ thông tin tài khoản đã liên kết vân tay (không bị xóa khi bấm Đăng xuất)
  static const String _keyBioToken = 'sg_bio_saved_token';
  static const String _keyBioUser = 'sg_bio_saved_user';

  static String? _cachedToken;
  static UserModel? _cachedUser;

  static Future<void> init() async {
    _cachedToken = await _secureStorage.read(key: _keyToken);
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(_keyUser);
    if (userStr != null && userStr.isNotEmpty) {
      try {
        _cachedUser = UserModel.fromJson(jsonDecode(userStr));
      } catch (_) {
        _cachedUser = null;
      }
    }
  }

  static String? get token => _cachedToken;
  static UserModel? get currentUser => _cachedUser;
  static bool get isLoggedIn => _cachedToken != null && _cachedToken!.isNotEmpty;
  static bool get isAdmin => (_cachedUser?.role.toLowerCase() ?? '') == 'admin';

  static Future<void> saveSession(String token, UserModel user) async {
    _cachedToken = token;
    _cachedUser = user;
    final userJson = jsonEncode({
      'id': user.id,
      'email': user.email,
      'username': user.username,
      'role': user.role,
      'isLocked': user.isLocked,
    });

    await _secureStorage.write(key: _keyToken, value: token);
    // Đồng thời lưu lại cho đăng nhập bằng Vân tay / Sinh trắc học lần sau
    await _secureStorage.write(key: _keyBioToken, value: token);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUser, userJson);
    await prefs.setString(_keyBioUser, userJson);
  }

  /// Khôi phục đúng tài khoản gần nhất khi xác thực Vân tay / Face ID thành công
  static Future<bool> restoreBiometricSession() async {
    final bioToken = await _secureStorage.read(key: _keyBioToken);
    final prefs = await SharedPreferences.getInstance();
    final bioUserStr = prefs.getString(_keyBioUser);

    if (bioToken == null || bioToken.isEmpty || bioUserStr == null || bioUserStr.isEmpty) {
      return false;
    }

    try {
      final user = UserModel.fromJson(jsonDecode(bioUserStr));
      _cachedToken = bioToken;
      _cachedUser = user;
      await _secureStorage.write(key: _keyToken, value: bioToken);
      await prefs.setString(_keyUser, bioUserStr);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lấy tên tài khoản đã liên kết vân tay (nếu có) để hiển thị trên nút Sinh trắc học
  static Future<UserModel?> getSavedBiometricUser() async {
    final prefs = await SharedPreferences.getInstance();
    final bioUserStr = prefs.getString(_keyBioUser);
    if (bioUserStr == null || bioUserStr.isEmpty) return null;
    try {
      return UserModel.fromJson(jsonDecode(bioUserStr));
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSession() async {
    _cachedToken = null;
    _cachedUser = null;
    await _secureStorage.delete(key: _keyToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUser);
  }

  static Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBiometricEnabled) ?? false;
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometricEnabled, enabled);
  }

  static Future<UserModel?> getCurrentUser() async {
    if (_cachedUser != null) return _cachedUser;
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(_keyUser) ?? prefs.getString(_keyBioUser);
    if (userStr != null && userStr.isNotEmpty) {
      try {
        _cachedUser = UserModel.fromJson(jsonDecode(userStr));
        return _cachedUser;
      } catch (_) {}
    }
    return null;
  }
}
