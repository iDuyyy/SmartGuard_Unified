DateTime? _parseNullableUtcToLocal(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;

  // Nếu chuỗi ISO từ SQL Server (DATETIME2) chưa có hậu tố múi giờ ('Z' hoặc '+/-HH:mm'),
  // tự động thêm 'Z' vì Backend luôn lưu DateTime.UtcNow, sau đó đổi về giờ địa phương (.toLocal())
  final hasTimezone = s.endsWith('Z') ||
      s.endsWith('z') ||
      (s.contains('T') &&
          (s.substring(s.indexOf('T')).contains('+') ||
              s.substring(s.indexOf('T')).contains('-')));

  final normalized = (s.contains('T') && !hasTimezone) ? '${s}Z' : s;
  final parsed = DateTime.tryParse(normalized);
  return parsed?.toLocal();
}

DateTime _parseUtcToLocal(dynamic raw) {
  return _parseNullableUtcToLocal(raw) ?? DateTime.now();
}

class UserModel {
  final String id;
  final String email;
  final String username;
  final String role;
  final bool isLocked;

  UserModel({
    required this.id,
    required this.email,
    required this.username,
    required this.role,
    this.isLocked = false,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id']?.toString() ?? json['userId']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      role: json['role']?.toString() ?? 'Owner',
      isLocked: json['isLocked'] == true,
    );
  }
}

class DeviceModel {
  final String id;
  final String ownerId;
  final String? zoneId;
  final String? zoneName;
  final String name;
  final String deviceCode;
  final String description;
  final bool isArmed;
  final double noiseThreshold;
  final double motionThreshold;
  final DateTime registeredAt;
  final DateTime lastSeenAt;
  final String deviceType; // camera | sensor | doorbell | siren
  final String location;   // Cửa chính | Phòng khách | Ban công | Sân trước | Sân sau

  DateTime get createdAt => registeredAt;

  DeviceModel({
    required this.id,
    this.ownerId = '',
    this.zoneId,
    this.zoneName,
    required this.name,
    this.deviceCode = '',
    this.description = '',
    this.isArmed = true,
    this.noiseThreshold = 70.0,
    this.motionThreshold = 3.5,
    DateTime? registeredAt,
    DateTime? lastSeenAt,
    DateTime? createdAt,
    String? deviceType,
    this.location = 'Cửa chính',
  })  : registeredAt = registeredAt ?? createdAt ?? DateTime.now(),
        lastSeenAt = lastSeenAt ?? createdAt ?? DateTime.now(),
        deviceType = deviceType ?? 'camera';

  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    final nameLower = (json['name']?.toString() ?? '').toLowerCase();
    final desc = json['description']?.toString() ?? '';
    final descLower = desc.toLowerCase();

    String detectedType = 'camera';
    if (descLower.contains('loại: doorbell') || nameLower.contains('chuông') || nameLower.contains('doorbell')) {
      detectedType = 'doorbell';
    } else if (descLower.contains('loại: sensor') || nameLower.contains('cảm biến') || nameLower.contains('sensor')) {
      detectedType = 'sensor';
    } else if (descLower.contains('loại: siren') || nameLower.contains('còi') || nameLower.contains('siren') || nameLower.contains('alarm')) {
      detectedType = 'siren';
    }

    String? parsedLocation;
    final locMatch = RegExp(r'Vị trí:\s*([^|]+)').firstMatch(desc);
    if (locMatch != null) {
      parsedLocation = locMatch.group(1)?.trim();
    }

    return DeviceModel(
      id: json['id']?.toString() ?? '',
      ownerId: json['ownerId']?.toString() ?? '',
      zoneId: json['zoneId']?.toString(),
      zoneName: json['zoneName']?.toString(),
      name: json['name']?.toString() ?? 'Thiết bị',
      deviceCode: json['deviceCode']?.toString() ?? '',
      description: desc,
      isArmed: json['isArmed'] == true,
      noiseThreshold: (json['noiseThreshold'] as num?)?.toDouble() ?? 70.0,
      motionThreshold: (json['motionThreshold'] as num?)?.toDouble() ?? 3.5,
      registeredAt: _parseUtcToLocal(json['registeredAt']),
      lastSeenAt: _parseUtcToLocal(json['lastSeenAt']),
      deviceType: json['deviceType']?.toString() ?? detectedType,
      location: json['zoneName']?.toString() ?? json['location']?.toString() ?? parsedLocation ?? 'Cửa chính',
    );
  }
}

class ZoneModel {
  final String id;
  final String name;
  final String description;
  final int deviceCount;

  ZoneModel({
    required this.id,
    required this.name,
    this.description = '',
    this.deviceCount = 0,
  });

  factory ZoneModel.fromJson(Map<String, dynamic> json) {
    return ZoneModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      deviceCount: (json['deviceCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class AlertModel {
  final String id;
  final String deviceId;
  final String deviceName;
  final String? zoneName;
  final String triggerReason;
  final double triggerScore;
  final String severity;
  final String status;
  final String? imageUrl;
  final String? adaptiveReason;
  final DateTime triggeredAt;
  final DateTime? acknowledgedAt;

  AlertModel({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    this.zoneName,
    required this.triggerReason,
    this.triggerScore = 0.0,
    required this.severity,
    required this.status,
    this.imageUrl,
    this.adaptiveReason,
    required this.triggeredAt,
    this.acknowledgedAt,
  });

  factory AlertModel.fromJson(Map<String, dynamic> json) {
    final rawImg = json['imageUrl']?.toString();
    final validImg = (rawImg != null && rawImg.isNotEmpty && !rawImg.contains('sample_alert.jpg'))
        ? rawImg
        : null;
    return AlertModel(
      id: json['id']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? 'Camera',
      zoneName: json['zoneName']?.toString(),
      triggerReason: json['triggerReason']?.toString() ?? 'CHUYEN_DONG',
      triggerScore: (json['triggerScore'] as num?)?.toDouble() ?? 0.0,
      severity: json['severity']?.toString() ?? 'Warning',
      status: json['status']?.toString() ?? 'Triggered',
      imageUrl: validImg,
      adaptiveReason: json['adaptiveReason']?.toString(),
      triggeredAt: _parseUtcToLocal(json['triggeredAt']),
      acknowledgedAt: _parseNullableUtcToLocal(json['acknowledgedAt']),
    );
  }
}

class MemberModel {
  final String id;
  final String memberUserId;
  final String memberEmail;
  final String memberUsername;
  final String? deviceId;
  final String? deviceName;
  final bool canAcknowledge;

  MemberModel({
    required this.id,
    required this.memberUserId,
    required this.memberEmail,
    required this.memberUsername,
    this.deviceId,
    this.deviceName,
    this.canAcknowledge = true,
  });

  factory MemberModel.fromJson(Map<String, dynamic> json) {
    return MemberModel(
      id: json['id']?.toString() ?? '',
      memberUserId: json['memberUserId']?.toString() ?? '',
      memberEmail: json['memberEmail']?.toString() ?? '',
      memberUsername: json['memberUsername']?.toString() ?? '',
      deviceId: json['deviceId']?.toString(),
      deviceName: json['deviceName']?.toString(),
      canAcknowledge: json['canAcknowledge'] == true,
    );
  }
}

class EmergencyContactModel {
  final String id;
  final String name;
  final String phone;
  final String relationship; // Bố, Mẹ, Vợ, Chồng, Con, Bạn thân, Hàng xóm
  final bool isCallAlert;
  final bool isSmsAlert;
  final String? email;

  EmergencyContactModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.relationship,
    this.isCallAlert = true,
    this.isSmsAlert = true,
    this.email,
  });

  factory EmergencyContactModel.fromJson(Map<String, dynamic> json) {
    return EmergencyContactModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      relationship: json['relationship']?.toString() ?? 'Người thân',
      isCallAlert: json['isCallAlert'] != false,
      isSmsAlert: json['isSmsAlert'] != false,
      email: json['email']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'relationship': relationship,
    'isCallAlert': isCallAlert,
    'isSmsAlert': isSmsAlert,
    'email': email,
  };
}

class AdaptiveZoneRuleModel {
  final String id;
  final String zoneId;
  final String zoneName;
  bool enableMonitoring;
  bool enableAlarmSound;
  bool enableDiscordNotification;
  double customSensitivity;

  AdaptiveZoneRuleModel({
    required this.id,
    required this.zoneId,
    required this.zoneName,
    this.enableMonitoring = true,
    this.enableAlarmSound = true,
    this.enableDiscordNotification = true,
    this.customSensitivity = 1.0,
  });

  factory AdaptiveZoneRuleModel.fromJson(Map<String, dynamic> json) {
    return AdaptiveZoneRuleModel(
      id: json['id']?.toString() ?? '',
      zoneId: json['zoneId']?.toString() ?? '',
      zoneName: json['zoneName']?.toString() ?? 'Khu vực',
      enableMonitoring: json['enableMonitoring'] != false,
      enableAlarmSound: json['enableAlarmSound'] != false,
      enableDiscordNotification: json['enableDiscordNotification'] != false,
      customSensitivity: (json['customSensitivity'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'zoneId': zoneId,
    'enableMonitoring': enableMonitoring,
    'enableAlarmSound': enableAlarmSound,
    'enableDiscordNotification': enableDiscordNotification,
    'customSensitivity': customSensitivity,
  };
}

class AdaptiveProfileModel {
  final String id;
  final String modeName;
  final String displayName;
  final String description;
  final bool isActive;
  final String activeFrom;
  final String activeTo;
  final String behaviorOnDisconnect;
  final DateTime? snoozeUntil;
  final bool isSnoozed;
  final List<AdaptiveZoneRuleModel> zoneRules;

  AdaptiveProfileModel({
    required this.id,
    required this.modeName,
    required this.displayName,
    required this.description,
    this.isActive = false,
    this.activeFrom = '00:00',
    this.activeTo = '23:59',
    this.behaviorOnDisconnect = 'AlertOffline',
    this.snoozeUntil,
    this.isSnoozed = false,
    this.zoneRules = const [],
  });

  factory AdaptiveProfileModel.fromJson(Map<String, dynamic> json) {
    final rawRules = json['zoneRules'] as List<dynamic>? ?? [];
    return AdaptiveProfileModel(
      id: json['id']?.toString() ?? '',
      modeName: json['modeName']?.toString() ?? 'Home',
      displayName: json['displayName']?.toString() ?? 'Ở nhà',
      description: json['description']?.toString() ?? '',
      isActive: json['isActive'] == true,
      activeFrom: json['activeFrom']?.toString() ?? '00:00',
      activeTo: json['activeTo']?.toString() ?? '23:59',
      behaviorOnDisconnect: json['behaviorOnDisconnect']?.toString() ?? 'AlertOffline',
      snoozeUntil: _parseNullableUtcToLocal(json['snoozeUntil']),
      isSnoozed: json['isSnoozed'] == true,
      zoneRules: rawRules.map((e) => AdaptiveZoneRuleModel.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class ImageItemModel {
  final String id;
  final String? deviceId;
  final String? alertEventId;
  final String fileName;
  final String relativeUrl;
  final DateTime uploadedAt;

  ImageItemModel({
    required this.id,
    this.deviceId,
    this.alertEventId,
    required this.fileName,
    required this.relativeUrl,
    required this.uploadedAt,
  });

  factory ImageItemModel.fromJson(Map<String, dynamic> json) {
    return ImageItemModel(
      id: json['id']?.toString() ?? '',
      deviceId: json['deviceId']?.toString(),
      alertEventId: json['alertEventId']?.toString(),
      fileName: json['fileName']?.toString() ?? '',
      relativeUrl: json['relativeUrl']?.toString() ?? '',
      uploadedAt: _parseUtcToLocal(json['uploadedAt']),
    );
  }
}

class KnownPersonModel {
  final String id;
  final String name;
  final String? photoPath;
  final String? photoUrl;
  final DateTime registeredAt;

  KnownPersonModel({
    required this.id,
    required this.name,
    this.photoPath,
    this.photoUrl,
    required this.registeredAt,
  });

  factory KnownPersonModel.fromJson(Map<String, dynamic> json) {
    return KnownPersonModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      photoPath: json['photoPath']?.toString(),
      photoUrl: json['photoUrl']?.toString(),
      registeredAt: _parseUtcToLocal(json['registeredAt']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'photoPath': photoPath,
    'photoUrl': photoUrl,
    'registeredAt': registeredAt.toIso8601String(),
  };
}
