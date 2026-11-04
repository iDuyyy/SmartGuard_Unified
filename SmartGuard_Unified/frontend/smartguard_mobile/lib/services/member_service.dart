import '../core/api_client.dart';
import '../core/session_manager.dart';
import '../models/models.dart';

/// Backend chưa có endpoint cho chức năng này → KHÔNG giả lập thành công.
class MemberFeatureUnsupported implements Exception {
  final String feature;
  final String endpoint;
  const MemberFeatureUnsupported(this.feature, this.endpoint);

  @override
  String toString() =>
      '';
}

/// Yêu cầu liên kết Member → Owner (chỉ có khi backend bổ sung API).
class MemberLinkRequest {
  final String id;
  final String requesterUserId;
  final String requesterEmail;
  final String requesterUsername;
  final DateTime? createdAt;

  const MemberLinkRequest({
    required this.id,
    required this.requesterUserId,
    required this.requesterEmail,
    required this.requesterUsername,
    this.createdAt,
  });

  factory MemberLinkRequest.fromJson(Map<String, dynamic> json) {
    return MemberLinkRequest(
      id: json['id']?.toString() ?? '',
      requesterUserId: (json['requesterUserId'] ?? json['memberUserId'] ?? '').toString(),
      requesterEmail: (json['requesterEmail'] ?? json['memberEmail'] ?? json['email'] ?? '').toString(),
      requesterUsername: (json['requesterUsername'] ?? json['memberUsername'] ?? json['username'] ?? '').toString(),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '')?.toLocal(),
    );
  }
}

/// Một Owner đang chia sẻ camera cho tôi (tôi là Member).
class SharedOwnerGroup {
  final String ownerId;
  final String ownerEmail; // rỗng nếu backend không trả
  final String ownerUsername;
  final bool? canAcknowledge; // null = backend không cho biết
  final List<DeviceModel> devices;

  const SharedOwnerGroup({
    required this.ownerId,
    this.ownerEmail = '',
    this.ownerUsername = '',
    this.canAcknowledge,
    this.devices = const [],
  });
}

class SharedWithMeResult {
  final List<SharedOwnerGroup> owners;

  /// true = dựng từ GET /api/devices vì backend chưa có API "được chia sẻ với tôi"
  /// (có thiết bị thật nhưng không có email Owner / quyền chi tiết).
  final bool derivedFromDevices;
  const SharedWithMeResult(this.owners, {this.derivedFromDevices = false});
}

/// Dữ liệu đọc được từ mã QR liên kết SmartGuard.
class MemberQrPayload {
  final String email;
  final String name;
  const MemberQrPayload(this.email, this.name);

  static const scheme = 'smartguard';

  /// QR chỉ chứa Gmail (định danh) + tên hiển thị, KHÔNG chứa token / mật khẩu.
  static String encode(String email, String name) {
    return Uri(
      scheme: scheme,
      host: 'member-link',
      queryParameters: {'email': email, if (name.isNotEmpty) 'name': name},
    ).toString();
  }

  static MemberQrPayload? decode(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

    if (emailRe.hasMatch(text)) return MemberQrPayload(text.toLowerCase(), '');

    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == scheme) {
      final email = (uri.queryParameters['email'] ?? '').trim().toLowerCase();
      if (emailRe.hasMatch(email)) {
        return MemberQrPayload(email, uri.queryParameters['name'] ?? '');
      }
    }
    if (text.toLowerCase().startsWith('mailto:')) {
      final email = text.substring(7).split('?').first.trim().toLowerCase();
      if (emailRe.hasMatch(email)) return MemberQrPayload(email, '');
    }
    return null;
  }
}

class MemberService {
  // ── Endpoint backend ĐÃ CÓ (MembersController) ──
  static const _list = '/api/members';
  static const _share = '/api/members/share';

  // ── Endpoint backend CHƯA CÓ (đề xuất, frontend gọi thật và báo lỗi nếu 404/405) ──
  static const _requests = '/api/members/requests';
  static const _incoming = '/api/members/requests/incoming';
  static const _sharedWithMe = '/api/members/shared-with-me';

  static bool _isMissingEndpoint(Object e) {
    if (e is! ApiException) return false;
    if (e.statusCode == 405) return true;
    // Route không tồn tại → ASP.NET trả 404 body rỗng (khác 404 có message nghiệp vụ)
    return e.statusCode == 404 && (e.message == 'Yêu cầu thất bại' || e.message == 'Not Found');
  }

  static String get myEmail => SessionManager.currentUser?.email ?? '';
  static String get myName => SessionManager.currentUser?.username ?? '';
  static String get myId => SessionManager.currentUser?.id ?? '';

  // ─────────────── OWNER: thành viên tôi đã cấp quyền ───────────────

  static Future<List<MemberModel>> getMyMembers() async {
    final res = await ApiClient.request('GET', _list);
    if (res is! List) return [];
    return res.map((e) => MemberModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Owner cấp quyền trực tiếp cho tài khoản có email này (API có sẵn).
  static Future<String> shareTo(String email, {String? deviceId, bool canAcknowledge = true}) async {
    final res = await ApiClient.request('POST', _share, body: {
      'memberEmail': email.trim().toLowerCase(),
      'deviceId': deviceId,
      'canAcknowledge': canAcknowledge,
    });
    return (res is Map && res['message'] != null) ? res['message'].toString() : 'Đã cấp quyền cho $email';
  }

  static Future<void> revoke(String accessId) async {
    await ApiClient.request('DELETE', '$_list/$accessId');
  }

  /// Sửa quyền của Member. Backend chưa có PUT /api/members/{id}, nên dùng 2 API thật có sẵn:
  /// cấp quyền mới (POST share) + thu hồi quyền cũ (DELETE). Nếu bước 2 lỗi sẽ cố khôi phục.
  /// Trả về true nếu đã phải dùng cách thay thế này.
  static Future<bool> updatePermission(
    MemberModel m, {
    required String? deviceId,
    required bool canAcknowledge,
  }) async {
    try {
      await ApiClient.request('PUT', '$_list/${m.id}', body: {
        'deviceId': deviceId,
        'canAcknowledge': canAcknowledge,
      });
      return false;
    } catch (e) {
      if (!_isMissingEndpoint(e)) rethrow;
    }

    final email = m.memberEmail;
    if (email.isEmpty) {
      throw const ApiException('Không có email của thành viên để cập nhật quyền.');
    }
    final sameScope = (m.deviceId ?? '') == (deviceId ?? '');

    if (!sameScope) {
      // Phạm vi khác → tạo quyền mới trước rồi mới xóa quyền cũ (không bao giờ mất quyền)
      await shareTo(email, deviceId: deviceId, canAcknowledge: canAcknowledge);
      await revoke(m.id);
      return true;
    }

    // Cùng phạm vi → backend chặn trùng nên phải xóa trước, lỗi thì khôi phục quyền cũ
    await revoke(m.id);
    try {
      await shareTo(email, deviceId: deviceId, canAcknowledge: canAcknowledge);
    } catch (e) {
      try {
        await shareTo(email, deviceId: m.deviceId, canAcknowledge: m.canAcknowledge);
      } catch (_) {}
      rethrow;
    }
    return true;
  }

  // ─────────────── OWNER: thiết bị của tôi (để chọn phạm vi quyền) ───────────────

  static Future<List<DeviceModel>> getMyOwnedDevices() async {
    final res = await ApiClient.request('GET', '/api/devices');
    if (res is! List) return [];
    final all = res.map((e) => DeviceModel.fromJson(e as Map<String, dynamic>)).toList();
    final id = myId;
    if (id.isEmpty) return all;
    return all.where((d) => d.ownerId.toLowerCase() == id.toLowerCase()).toList();
  }

  // ─────────────── YÊU CẦU LIÊN KẾT (backend CHƯA CÓ) ───────────────

  /// Member gửi yêu cầu liên kết tới Owner (email lấy từ QR).
  static Future<void> sendLinkRequest(String ownerEmail) async {
    try {
      await ApiClient.request('POST', _requests, body: {'ownerEmail': ownerEmail.trim().toLowerCase()});
    } catch (e) {
      if (_isMissingEndpoint(e)) {
        throw const MemberFeatureUnsupported('Gửi yêu cầu liên kết', 'POST /api/members/requests');
      }
      rethrow;
    }
  }

  /// Owner xem các yêu cầu liên kết đang chờ.
  static Future<List<MemberLinkRequest>> getIncomingRequests() async {
    try {
      final res = await ApiClient.request('GET', _incoming);
      if (res is! List) return [];
      return res.map((e) => MemberLinkRequest.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      if (_isMissingEndpoint(e)) {
        throw const MemberFeatureUnsupported('Danh sách yêu cầu liên kết', 'GET /api/members/requests/incoming');
      }
      rethrow;
    }
  }

  /// Owner chấp nhận / từ chối yêu cầu.
  static Future<void> respondRequest(
    String requestId, {
    required bool accept,
    String? deviceId,
    bool canAcknowledge = true,
  }) async {
    final path = '$_requests/$requestId/${accept ? 'accept' : 'reject'}';
    try {
      await ApiClient.request('POST', path, body: {
        if (accept) 'deviceId': deviceId,
        if (accept) 'canAcknowledge': canAcknowledge,
      });
    } catch (e) {
      if (_isMissingEndpoint(e)) {
        throw MemberFeatureUnsupported(
          accept ? 'Chấp nhận yêu cầu' : 'Từ chối yêu cầu',
          'POST /api/members/requests/{id}/${accept ? 'accept' : 'reject'}',
        );
      }
      rethrow;
    }
  }

  // ─────────────── MEMBER: Owner nào đang chia sẻ cho tôi ───────────────

  static Future<SharedWithMeResult> getSharedWithMe() async {
    try {
      final res = await ApiClient.request('GET', _sharedWithMe);
      if (res is List) {
        final groups = res.map((e) {
          final j = e as Map<String, dynamic>;
          return SharedOwnerGroup(
            ownerId: j['ownerId']?.toString() ?? '',
            ownerEmail: j['ownerEmail']?.toString() ?? '',
            ownerUsername: j['ownerUsername']?.toString() ?? '',
            canAcknowledge: j['canAcknowledge'] is bool ? j['canAcknowledge'] as bool : null,
          );
        }).toList();
        return SharedWithMeResult(groups);
      }
      return const SharedWithMeResult([]);
    } catch (e) {
      if (!_isMissingEndpoint(e)) rethrow;
    }

    // Thay thế bằng dữ liệu thật từ GET /api/devices: thiết bị có ownerId khác tôi = được chia sẻ.
    final id = myId.toLowerCase();
    if (id.isEmpty) return const SharedWithMeResult([], derivedFromDevices: true);
    final res = await ApiClient.request('GET', '/api/devices');
    if (res is! List) return const SharedWithMeResult([], derivedFromDevices: true);

    final shared = res
        .map((e) => DeviceModel.fromJson(e as Map<String, dynamic>))
        .where((d) => d.ownerId.isNotEmpty && d.ownerId.toLowerCase() != id)
        .toList();

    final byOwner = <String, List<DeviceModel>>{};
    for (final d in shared) {
      byOwner.putIfAbsent(d.ownerId, () => []).add(d);
    }
    return SharedWithMeResult(
      byOwner.entries.map((en) => SharedOwnerGroup(ownerId: en.key, devices: en.value)).toList(),
      derivedFromDevices: true,
    );
  }
}
