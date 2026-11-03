import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class EmergencyService {
  static const String _keyContacts = 'sg_emergency_contacts';
  static const Set<String> _demoIds = {'1', '2', '3'};

  /// Lấy danh sách liên hệ khẩn cấp (người thân) đã lưu
  static Future<List<EmergencyContactModel>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyContacts);
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      final List<dynamic> list = jsonDecode(raw);
      final parsed = list
          .map((e) => EmergencyContactModel.fromJson(e as Map<String, dynamic>))
          .toList();
      // Nếu trong danh sách đã có liên hệ thật do người dùng thêm, loại bỏ 3 số mẫu ảo cũ
      final hasRealContact = parsed.any((c) => !_demoIds.contains(c.id));
      if (hasRealContact) {
        final cleaned = parsed.where((c) => !_demoIds.contains(c.id)).toList();
        if (cleaned.length != parsed.length) {
          await saveContacts(cleaned);
        }
        return cleaned;
      }
      return parsed;
    } catch (_) {
      return [];
    }
  }

  /// Lấy liên hệ ưu tiên số 1 sẽ được gọi điện khi có báo động
  static Future<EmergencyContactModel?> getPrimaryCallContact() async {
    final contacts = await getContacts();
    final callList = contacts.where((c) => c.isCallAlert && c.phone.trim().isNotEmpty).toList();
    if (callList.isEmpty) return null;
    // Ưu tiên số thật do người dùng thêm trước
    final realCallList = callList.where((c) => !_demoIds.contains(c.id)).toList();
    if (realCallList.isNotEmpty) return realCallList.first;
    return callList.first;
  }

  /// Lưu toàn bộ danh sách liên hệ khẩn cấp
  static Future<void> saveContacts(List<EmergencyContactModel> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(contacts.map((c) => c.toJson()).toList());
    await prefs.setString(_keyContacts, encoded);
  }

  /// Thêm người thân mới (Đặt lên ĐẦU danh sách làm số ưu tiên gọi chính và xóa số mẫu ảo)
  static Future<List<EmergencyContactModel>> addContact(EmergencyContactModel contact) async {
    final current = await getContacts();
    current.removeWhere((c) => _demoIds.contains(c.id));
    current.insert(0, contact);
    await saveContacts(current);
    return current;
  }

  /// Đặt một người thân lên đầu danh sách làm Số ưu tiên gọi khẩn cấp số 1
  static Future<List<EmergencyContactModel>> setPrimaryContact(String id) async {
    final current = await getContacts();
    final idx = current.indexWhere((c) => c.id == id);
    if (idx > 0) {
      final item = current.removeAt(idx);
      current.insert(0, item);
      await saveContacts(current);
    }
    return current;
  }

  /// Cập nhật thông tin người thân
  static Future<List<EmergencyContactModel>> updateContact(EmergencyContactModel updated) async {
    final current = await getContacts();
    final index = current.indexWhere((c) => c.id == updated.id);
    if (index != -1) {
      current[index] = updated;
      await saveContacts(current);
    }
    return current;
  }

  /// Xóa người thân khỏi danh sách khẩn cấp
  static Future<List<EmergencyContactModel>> deleteContact(String id) async {
    final current = await getContacts();
    current.removeWhere((c) => c.id == id);
    await saveContacts(current);
    return current;
  }

  /// Trả về danh sách người thân cần gọi điện và nhắn tin khi có báo động
  static Future<Map<String, dynamic>> dispatchEmergencyAlert({
    required String reason,
    String location = 'SmartGuard App',
  }) async {
    final contacts = await getContacts();
    final callList = contacts
        .where((c) => c.isCallAlert && c.phone.trim().isNotEmpty)
        .toList();
    final smsList = contacts
        .where((c) => c.isSmsAlert && c.phone.trim().isNotEmpty)
        .toList();

    return {
      'callList': callList,
      'smsList': smsList,
      'primaryPhone': callList.isNotEmpty ? callList.first.phone : null,
      'primaryName': callList.isNotEmpty ? callList.first.name : null,
      'reason': reason,
      'location': location,
    };
  }
}
