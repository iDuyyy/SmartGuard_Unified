import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String defaultTunnelUrl =
      'https://smartguard-unified.onrender.com/';
  static const String defaultLanUrl = 'http://192.168.1.100:5235';
  static const String emulatorUrl = 'http://10.0.2.2:5235';
  static const String localhostUrl = 'https://localhost:44321';
  static const String renderUrl =
      'https://smartguard-unified.onrender.com';

  static String _activeBaseUrl = renderUrl;
  static const String _prefKeyBaseUrl = 'smartguard_base_url';

  static String get baseUrl => _activeBaseUrl;

  /// Danh sách các địa chỉ ứng viên để tự động dò tìm khi mất kết nối
  static List<String> get candidateUrls => <String>{
    _activeBaseUrl,
    renderUrl,
    localhostUrl,
    'http://127.0.0.1:5235',
    emulatorUrl,
    defaultTunnelUrl,
  }.toList();

  static const double faceMatchThreshold = 0.80;
  static const double defaultMotionThreshold = 3.5;
  static const double defaultNoiseThreshold = 70.0;

  /// Chuẩn hóa chuỗi URL người dùng nhập (thêm http:// nếu thiếu, bỏ hậu tố dư thừa)
  static String normalizeUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return localhostUrl;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    for (final suffix in [
      '/api/status',
      '/api',
      '/swagger/index.html',
      '/swagger',
    ]) {
      if (trimmed.toLowerCase().endsWith(suffix)) {
        trimmed = trimmed.substring(0, trimmed.length - suffix.length);
      }
    }
    return trimmed;
  }

  /// Ghép Base URL và đường dẫn API an toàn (giữ nguyên cả path prefix lẫn query string)
  static Uri buildUri(
    String path, [
    Map<String, String>? queryParams,
    String? customBaseUrl,
  ]) {
    final base = normalizeUrl(customBaseUrl ?? _activeBaseUrl);
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$cleanPath');
    if (queryParams == null || queryParams.isEmpty) return uri;
    final mergedQuery = <String, String>{
      ...uri.queryParameters,
      ...queryParams,
    };
    return uri.replace(queryParameters: mergedQuery);
  }

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      _activeBaseUrl = renderUrl;

      await prefs.setString(
        _prefKeyBaseUrl,
        renderUrl,
      );
    } catch (_) {
      _activeBaseUrl = renderUrl;
    }
      final saved = prefs.getString(_prefKeyBaseUrl);
      if (saved != null &&
          saved.trim().isNotEmpty &&
          !saved.contains('192.168.2.6')) {
        _activeBaseUrl = normalizeUrl(saved);
      } else {
        _activeBaseUrl = localhostUrl;
        await prefs.setString(_prefKeyBaseUrl, _activeBaseUrl);
      }
    } catch (_) {}
  }

  static Future<void> setBaseUrl(String url) async {
    final normalized = normalizeUrl(url);
    _activeBaseUrl = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyBaseUrl, normalized);
    } catch (_) {}
  }
}
