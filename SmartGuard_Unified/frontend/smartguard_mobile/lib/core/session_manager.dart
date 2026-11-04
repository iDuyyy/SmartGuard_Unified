import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Kết quả khôi phục phiên bằng vân tay.
enum BiometricRestoreStatus {
  success,
  notLinked, // Chưa có tài khoản nào liên kết vân tay trên máy
  tokenMissing, // Có tài khoản liên kết nhưng token đã bị máy chủ thu hồi (401)
  tokenExpired, // JWT đã quá hạn (exp)
  accountMismatch, // Token không thuộc về tài khoản đã liên kết
}

class BiometricRestoreResult {
  final BiometricRestoreStatus status;
  final UserModel? user;
  const BiometricRestoreResult(this.status, [this.user]);
  bool get ok => status == BiometricRestoreStatus.success;
}

/// Quản lý 2 loại dữ liệu tách biệt:
///  1. PHIÊN HIỆN TẠI (token + user)  → bị xóa khi Đăng xuất.
///  2. LIÊN KẾT VÂN TAY (token + user của tài khoản đã bật vân tay)
///     → lưu trong Secure Storage (Android Keystore), KHÔNG bị xóa khi Đăng xuất,
///       chỉ bị xóa khi người dùng TẮT đăng nhập vân tay.
class SessionManager {
  static const _secureStorage = FlutterSecureStorage();

  // Phiên hiện tại
  static const String _keyToken = 'sg_jwt_token';
  static const String _keyUser = 'sg_user_info';

  // Liên kết sinh trắc học
  static const String _keyBiometricEnabled = 'sg_biometric_enabled';
  static const String _keyBioToken = 'sg_bio_saved_token';
  static const String _keyBioUser = 'sg_bio_saved_user'; // secure storage (bản cũ nằm ở SharedPreferences)

  static String? _cachedToken;
  static UserModel? _cachedUser;

  /// Gọi khi máy chủ trả 401 (token hết hạn) để app quay về màn hình chào.
  static void Function()? onSessionExpired;

  static Future<void> init() async {
    _cachedToken = await _secureStorage.read(key: _keyToken);
    final prefs = await SharedPreferences.getInstance();
    _cachedUser = _decodeUser(prefs.getString(_keyUser));
    await _migrateLegacyBiometricUser(prefs);
  }

  static String? get token => _cachedToken;
  static UserModel? get currentUser => _cachedUser;
  static bool get isLoggedIn => _cachedToken != null && _cachedToken!.isNotEmpty;
  static bool get isAdmin => (_cachedUser?.role.toLowerCase() ?? '') == 'admin';

  // ─────────────────────────── PHIÊN HIỆN TẠI ───────────────────────────

  /// Lưu phiên sau khi đăng nhập mật khẩu + OTP thành công.
  /// KHÔNG tự bật vân tay. Nếu tài khoản này chính là tài khoản đã liên kết vân tay
  /// thì làm mới token của liên kết để lần sau đăng nhập vân tay không bị hết hạn.
  static Future<void> saveSession(String token, UserModel rawUser) async {
    final user = _enrichUserFromToken(token, rawUser);
    _cachedToken = token;
    _cachedUser = user;

    await _secureStorage.write(key: _keyToken, value: token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUser, _encodeUser(user));

    final bioUser = await getSavedBiometricUser();
    if (bioUser != null && _sameAccount(bioUser, user)) {
      await _secureStorage.write(key: _keyBioToken, value: token);
      await _secureStorage.write(key: _keyBioUser, value: _encodeUser(user));
    }
  }

  /// Đăng xuất thông thường: chỉ xóa phiên hiện tại, GIỮ liên kết vân tay.
  static Future<void> clearSession() async {
    _cachedToken = null;
    _cachedUser = null;
    await _secureStorage.delete(key: _keyToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUser);
  }

  /// Máy chủ báo 401: xóa phiên; nếu token hỏng chính là token vân tay thì
  /// thu hồi token đó (giữ tên tài khoản để nhắc đăng nhập mật khẩu làm mới).
  static Future<void> handleUnauthorized() async {
    final badToken = _cachedToken;
    if (badToken == null || badToken.isEmpty) return;
    // Xóa ngay trong bộ nhớ để nhiều request 401 song song chỉ điều hướng 1 lần
    _cachedToken = null;
    _cachedUser = null;
    final bioToken = await _secureStorage.read(key: _keyBioToken);
    if (bioToken == badToken) {
      await _secureStorage.delete(key: _keyBioToken);
    }
    await clearSession();
    onSessionExpired?.call();
  }

  static Future<UserModel?> getCurrentUser() async {
    if (_cachedUser != null) return _cachedUser;
    final prefs = await SharedPreferences.getInstance();
    _cachedUser = _decodeUser(prefs.getString(_keyUser));
    return _cachedUser;
  }

  // ─────────────────────────── LIÊN KẾT VÂN TAY ───────────────────────────

  /// Bật vân tay cho TÀI KHOẢN ĐANG ĐĂNG NHẬP (gọi sau khi quét vân tay xác nhận).
  static Future<bool> enableBiometricForCurrentUser() async {
    final token = _cachedToken;
    final user = _cachedUser ?? await getCurrentUser();
    if (token == null || token.isEmpty || user == null) return false;

    await _secureStorage.write(key: _keyBioToken, value: token);
    await _secureStorage.write(key: _keyBioUser, value: _encodeUser(user));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometricEnabled, true);
    return true;
  }

  /// Xóa liên kết sinh trắc học hoàn toàn (khi người dùng TẮT vân tay).
  static Future<void> removeBiometricBinding() async {
    await _secureStorage.delete(key: _keyBioToken);
    await _secureStorage.delete(key: _keyBioUser);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyBioUser);
    await prefs.setBool(_keyBiometricEnabled, false);
  }

  /// Vân tay chỉ được coi là BẬT khi cờ bật = true VÀ thật sự có tài khoản liên kết.
  static Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final flag = prefs.getBool(_keyBiometricEnabled) ?? false;
    if (!flag) return false;
    return (await getSavedBiometricUser()) != null;
  }

  /// Vân tay đang liên kết với chính tài khoản đang đăng nhập hay không.
  static Future<bool> isBiometricLinkedToCurrentUser() async {
    final user = _cachedUser ?? await getCurrentUser();
    if (user == null) return false;
    if (!await isBiometricEnabled()) return false;
    final bioUser = await getSavedBiometricUser();
    return bioUser != null && _sameAccount(bioUser, user);
  }

  /// Tài khoản đã liên kết vân tay (để hiển thị trên nút đăng nhập vân tay).
  static Future<UserModel?> getSavedBiometricUser() async {
    return _decodeUser(await _secureStorage.read(key: _keyBioUser));
  }

  /// Khôi phục ĐÚNG tài khoản đã liên kết sau khi quét vân tay thành công.
  static Future<BiometricRestoreResult> restoreBiometricSession() async {
    if (!await isBiometricEnabled()) {
      return const BiometricRestoreResult(BiometricRestoreStatus.notLinked);
    }
    final bioUser = await getSavedBiometricUser();
    if (bioUser == null) {
      return const BiometricRestoreResult(BiometricRestoreStatus.notLinked);
    }

    final bioToken = await _secureStorage.read(key: _keyBioToken);
    if (bioToken == null || bioToken.isEmpty) {
      return BiometricRestoreResult(BiometricRestoreStatus.tokenMissing, bioUser);
    }

    final claims = _decodeJwtClaims(bioToken);
    if (claims != null) {
      final exp = claims['exp'];
      if (exp is num) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
        if (DateTime.now().isAfter(expiry)) {
          await _secureStorage.delete(key: _keyBioToken);
          return BiometricRestoreResult(BiometricRestoreStatus.tokenExpired, bioUser);
        }
      }
      if (!_tokenBelongsTo(claims, bioUser)) {
        await _secureStorage.delete(key: _keyBioToken);
        return BiometricRestoreResult(BiometricRestoreStatus.accountMismatch, bioUser);
      }
    }

    final user = _enrichUserFromToken(bioToken, bioUser);
    _cachedToken = bioToken;
    _cachedUser = user;
    await _secureStorage.write(key: _keyToken, value: bioToken);
    await _secureStorage.write(key: _keyBioUser, value: _encodeUser(user));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUser, _encodeUser(user));
    return BiometricRestoreResult(BiometricRestoreStatus.success, user);
  }

  // ─────────────────────────── HỖ TRỢ ───────────────────────────

  static String _encodeUser(UserModel user) {
    final validUsername = user.username.isNotEmpty
        ? user.username
        : (user.email.isNotEmpty ? user.email.split('@').first : '');
    return jsonEncode({
      'id': user.id,
      'email': user.email,
      'username': validUsername,
      'role': user.role,
      'isLocked': user.isLocked,
    });
  }

  static UserModel? _decodeUser(String? str) {
    if (str == null || str.isEmpty) return null;
    try {
      return UserModel.fromJson(jsonDecode(str) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static bool _sameAccount(UserModel a, UserModel b) {
    if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
    if (a.email.isNotEmpty && b.email.isNotEmpty) {
      return a.email.toLowerCase() == b.email.toLowerCase();
    }
    return a.username.isNotEmpty && a.username == b.username;
  }

  static Map<String, dynamic>? _decodeJwtClaims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final data = jsonDecode(payload);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// So khớp claim định danh trong JWT với tài khoản đã liên kết.
  /// Token không có claim định danh nào thì không chặn.
  static bool _tokenBelongsTo(Map<String, dynamic> claims, UserModel user) {
    final values = [..._idKeys, ..._emailKeys, ..._nameKeys]
        .map((k) => claims[k]?.toString().toLowerCase())
        .whereType<String>()
        .where((v) => v.isNotEmpty)
        .toSet();

    if (values.isEmpty) return true;
    final mine = [user.id, user.email, user.username]
        .map((v) => v.toLowerCase())
        .where((v) => v.isNotEmpty)
        .toList();
    if (mine.isEmpty) return true;
    return mine.any(values.contains);
  }

  static const _idKeys = [
    'sub',
    'nameid',
    'userId',
    'uid',
    'id',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier',
  ];
  static const _emailKeys = [
    'email',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress',
  ];
  static const _nameKeys = [
    'unique_name',
    'name',
    'username',
    'preferred_username',
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name',
  ];
  static const _roleKeys = [
    'role',
    'http://schemas.microsoft.com/ws/2008/06/identity/claims/role',
  ];

  static String _firstClaim(Map<String, dynamic> claims, List<String> keys) {
    for (final k in keys) {
      final v = claims[k];
      final str = v is List ? (v.isNotEmpty ? v.first.toString() : '') : (v?.toString() ?? '');
      if (str.isNotEmpty) return str;
    }
    return '';
  }

  /// Nếu máy chủ trả thiếu id / email / username thì lấy từ JWT,
  /// để liên kết vân tay luôn gắn với tài khoản thật (không rơi về "User" mặc định).
  static UserModel _enrichUserFromToken(String token, UserModel user) {
    final claims = _decodeJwtClaims(token);
    if (claims == null) return user;
    final id = user.id.isNotEmpty ? user.id : _firstClaim(claims, _idKeys);
    final email = user.email.isNotEmpty ? user.email : _firstClaim(claims, _emailKeys);
    final isPlaceholderName = user.username.isEmpty || user.username == 'User';
    final claimName = _firstClaim(claims, _nameKeys);
    final username = isPlaceholderName
        ? (claimName.isNotEmpty ? claimName : (email.isNotEmpty ? email.split('@').first : user.username))
        : user.username;
    final claimRole = _firstClaim(claims, _roleKeys);
    final role = claimRole.isNotEmpty ? claimRole : user.role;
    return UserModel(id: id, email: email, username: username, role: role, isLocked: user.isLocked);
  }

  /// Bản cũ lưu tài khoản vân tay ở SharedPreferences → chuyển sang Secure Storage.
  static Future<void> _migrateLegacyBiometricUser(SharedPreferences prefs) async {
    final legacy = prefs.getString(_keyBioUser);
    if (legacy == null || legacy.isEmpty) return;
    final existing = await _secureStorage.read(key: _keyBioUser);
    if (existing == null || existing.isEmpty) {
      await _secureStorage.write(key: _keyBioUser, value: legacy);
    }
    await prefs.remove(_keyBioUser);
  }
}
