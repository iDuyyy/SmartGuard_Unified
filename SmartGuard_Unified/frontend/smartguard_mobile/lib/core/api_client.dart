import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'app_config.dart';
import 'session_manager.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  const ApiException(this.message, [this.statusCode]);

  @override
  String toString() => statusCode != null ? 'HTTP $statusCode: $message' : message;
}

class ConnectionCheckResult {
  final bool ok;
  final String url;
  final int? statusCode;
  final int latencyMs;
  final String message;
  final String? serverVersion;

  const ConnectionCheckResult({
    required this.ok,
    required this.url,
    required this.latencyMs,
    required this.message,
    this.statusCode,
    this.serverVersion,
  });
}

class ApiClient {
  static final http.Client _client = http.Client();

  static Future<dynamic> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await _sendRequest(
        method,
        path,
        body: body,
        queryParams: queryParams,
        timeout: timeout,
      );
    } on ApiException catch (firstErr) {
      // Nếu lỗi kết nối mạng (chưa có statusCode HTTP), thử tự động dò sang URL dự phòng 1 lần
      if (firstErr.statusCode == null) {
        final switched = await _trySwitchToReachableBaseUrl();
        if (switched) {
          return await _sendRequest(
            method,
            path,
            body: body,
            queryParams: queryParams,
            timeout: timeout,
          );
        }
      }
      rethrow;
    }
  }

  static Future<dynamic> _sendRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParams,
    required Duration timeout,
  }) async {
    final finalUri = AppConfig.buildUri(path, queryParams);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Tunnel-Skip-AntiPhishing-Page': 'true',
    };

    final token = SessionManager.token;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    try {
      http.Response response;
      final payload = body != null ? jsonEncode(body) : null;

      switch (method.toUpperCase()) {
        case 'GET':
          response = await _client.get(finalUri, headers: headers).timeout(timeout);
          break;
        case 'POST':
          response = await _client.post(finalUri, headers: headers, body: payload).timeout(timeout);
          break;
        case 'PUT':
          response = await _client.put(finalUri, headers: headers, body: payload).timeout(timeout);
          break;
        case 'PATCH':
          response = await _client.patch(finalUri, headers: headers, body: payload).timeout(timeout);
          break;
        case 'DELETE':
          response = await _client.delete(finalUri, headers: headers).timeout(timeout);
          break;
        default:
          throw ApiException('Phương thức HTTP không hỗ trợ: $method');
      }

      return _handleResponse(response);
    } on SocketException {
      throw ApiException(
        'Không thể kết nối đến máy chủ (${AppConfig.baseUrl}). Vui lòng kiểm tra Backend đã bật và cấu hình IP.',
      );
    } on TimeoutException {
      throw ApiException(
        'Hết thời gian chờ phản hồi từ máy chủ (${AppConfig.baseUrl}).',
      );
    } on FormatException {
      throw const ApiException('Địa chỉ URL máy chủ không hợp lệ.');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('Lỗi kết nối: $e');
    }
  }

  static Future<dynamic> uploadFile(
    String path,
    File file, {
    Map<String, String>? fields,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = AppConfig.buildUri(path);

    final request = http.MultipartRequest('POST', uri);

    request.headers['X-Tunnel-Skip-AntiPhishing-Page'] = 'true';
    final token = SessionManager.token;
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    if (fields != null) {
      request.fields.addAll(fields);
    }

    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    try {
      final streamedResponse = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse).timeout(timeout);
      return _handleResponse(response);
    } on SocketException {
      throw const ApiException('Lỗi kết nối mạng khi tải ảnh lên.');
    } on TimeoutException {
      throw const ApiException('Hết thời gian chờ khi tải ảnh bằng chứng lên máy chủ.');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('Lỗi tải file: $e');
    }
  }

  static dynamic _handleResponse(http.Response response) {
    dynamic data;
    try {
      if (response.body.isNotEmpty) {
        data = jsonDecode(response.body);
      }
    } catch (_) {
      data = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }

    if (response.statusCode == 401) {
      // Token hết hạn / bị thu hồi: xóa phiên và đưa người dùng về màn hình đăng nhập
      SessionManager.handleUnauthorized();
      throw const ApiException('Phiên đăng nhập đã hết hạn hoặc không hợp lệ. Vui lòng đăng nhập lại.', 401);
    }

    var errorMessage = 'Yêu cầu thất bại';
    if (data is Map) {
      if (data.containsKey('message') && data['message'] != null && data['message'].toString().isNotEmpty) {
        errorMessage = data['message'].toString();
      } else if (data.containsKey('errors') && data['errors'] is Map) {
        final errMap = data['errors'] as Map;
        final List<String> errList = [];
        errMap.forEach((k, v) {
          if (v is List) {
            errList.addAll(v.map((e) => e.toString()));
          } else if (v != null) {
            errList.add(v.toString());
          }
        });
        if (errList.isNotEmpty) {
          errorMessage = errList.join('; ');
        }
      } else if (data.containsKey('error') && data['error'] != null) {
        errorMessage = data['error'].toString();
      } else if (data.containsKey('title') && data['title'] != null) {
        errorMessage = data['title'].toString();
      }
    }

    throw ApiException(errorMessage, response.statusCode);
  }

  /// Kiểm tra chi tiết kết nối tới `/api/status` của SmartGuard Backend
  static Future<ConnectionCheckResult> testConnectionDetailed([String? customUrl]) async {
    final normalized = AppConfig.normalizeUrl(customUrl ?? AppConfig.baseUrl);
    final sw = Stopwatch()..start();
    try {
      final statusUri = AppConfig.buildUri('/api/status', null, normalized);
      final res = await _client.get(
        statusUri,
        headers: {
          'Accept': 'application/json',
          'X-Tunnel-Skip-AntiPhishing-Page': 'true',
        },
      ).timeout(const Duration(seconds: 5));
      sw.stop();

      if (res.statusCode == 200) {
        try {
          final json = jsonDecode(res.body);
          if (json is Map && json['status']?.toString().toLowerCase() == 'online') {
            final version = json['version']?.toString();
            return ConnectionCheckResult(
              ok: true,
              url: normalized,
              statusCode: 200,
              latencyMs: sw.elapsedMilliseconds,
              serverVersion: version,
              message: 'Kết nối thành công tới $normalized (${sw.elapsedMilliseconds}ms)'
                  '${version != null ? " • v$version" : ""}',
            );
          }
        } catch (_) {}
        return ConnectionCheckResult(
          ok: true,
          url: normalized,
          statusCode: 200,
          latencyMs: sw.elapsedMilliseconds,
          message: 'Kết nối máy chủ thành công ($normalized • ${sw.elapsedMilliseconds}ms)',
        );
      }

      return ConnectionCheckResult(
        ok: false,
        url: normalized,
        statusCode: res.statusCode,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Máy chủ phản hồi mã HTTP ${res.statusCode} tại $normalized.',
      );
    } on TimeoutException {
      sw.stop();
      return ConnectionCheckResult(
        ok: false,
        url: normalized,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Quá thời gian chờ (5s) tới $normalized. Kiểm tra tường lửa hoặc IP.',
      );
    } on SocketException {
      sw.stop();
      return ConnectionCheckResult(
        ok: false,
        url: normalized,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Không thể kết nối tới $normalized. Hãy đảm bảo Backend đang chạy ở cổng 5235.',
      );
    } catch (e) {
      sw.stop();
      return ConnectionCheckResult(
        ok: false,
        url: normalized,
        latencyMs: sw.elapsedMilliseconds,
        message: 'Lỗi kiểm tra kết nối ($normalized): $e',
      );
    }
  }

  /// Kiểm tra kết nối; nếu không truyền [customUrl] và URL hiện tại thất bại,
  /// tự động dò qua danh sách ứng viên (Localhost, Emulator 10.0.2.2, Tunnel) và lưu lại URL sống.
  static Future<bool> testConnection([String? customUrl]) async {
    if (customUrl != null && customUrl.trim().isNotEmpty) {
      final result = await testConnectionDetailed(customUrl);
      return result.ok;
    }

    final current = await testConnectionDetailed(AppConfig.baseUrl);
    if (current.ok) return true;

    return await _trySwitchToReachableBaseUrl();
  }

  static Future<bool> _trySwitchToReachableBaseUrl() async {
    for (final candidate in AppConfig.candidateUrls) {
      if (candidate == AppConfig.baseUrl) continue;
      final check = await testConnectionDetailed(candidate);
      if (check.ok) {
        await AppConfig.setBaseUrl(check.url);
        return true;
      }
    }
    return false;
  }

  /// Kiểm tra JWT token hiện tại còn hiệu lực với máy chủ hay không
  static Future<bool> validateCurrentToken() async {
    final token = SessionManager.token;
    if (token == null || token.isEmpty) return false;

    try {
      final statusUri = AppConfig.buildUri('/api/status');
      final res = await _client.get(
        statusUri,
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
          'X-Tunnel-Skip-AntiPhishing-Page': 'true',
        },
      ).timeout(const Duration(seconds: 4));

      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return true;
    }
  }
}
