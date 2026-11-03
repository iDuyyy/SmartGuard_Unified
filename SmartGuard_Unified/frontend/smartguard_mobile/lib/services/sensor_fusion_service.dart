import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import '../services/emergency_service.dart';
import '../services/foreground_service_controller.dart';
import '../services/sound_classifier_service.dart';
import '../services/tts_service.dart';
import '../core/api_client.dart';
import '../models/models.dart';

// ─── Alert Severity ────────────────────────────────────────────────────────
enum AlertSeverity { low, medium, high, critical }

// ─── Sensor Fusion Result ──────────────────────────────────────────────────
class FusionResult {
  final double score;        // 0.0 – 1.0
  final AlertSeverity level;
  final String reason;
  final Map<String, double> breakdown;

  const FusionResult({
    required this.score,
    required this.level,
    required this.reason,
    required this.breakdown,
  });
}

/// SensorFusionService — Kết hợp dữ liệu cảm biến gia tốc + ML âm thanh (TFLite)
/// để tính điểm nguy cơ và kích hoạt chuỗi báo động tự động.
///
/// Thuật toán trọng số kết hợp Peak + Synergy:
///   Motion  : 40%
///   Sound   : 40%
///   Vision  : 20%
///
/// Khi `fusedScore >= triggerThreshold` → kích hoạt AlertOrchestrator.
class SensorFusionService {
  // Trọng số
  static const double _wMotion = 0.40;
  static const double _wSound  = 0.40;
  static const double _wVision = 0.20;

  // Ngưỡng kích hoạt mặc định (có thể tuỳ chỉnh qua Settings)
  double triggerThreshold = 0.65;

  // Ngưỡng chuyển động gia tốc kế (m/s²)
  double motionThreshold = 3.5;

  // Kết quả âm thanh hiện tại từ SoundClassifierService (YAMNet)
  double soundConfidence = 0.0; // điểm nguy cơ có trọng số 0.0–1.0
  String soundLabel = 'Silence';
  StreamSubscription<SoundClassificationResult>? _soundSub;

  // Giá trị vision từ ML Kit face detection (0.0–1.0)
  double visionScore = 0.0;

  // Giá trị motion từ accelerometer (chuẩn hoá 0.0–1.0)
  double _motionScore = 0.0;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  final _fusionController = StreamController<FusionResult>.broadcast();

  Stream<FusionResult> get fusionStream => _fusionController.stream;

  bool _isRunning = false;

  // Đường cơ sở trọng lực (lọc thông thấp) — loại bỏ 9.81 m/s² tĩnh
  double _gravityBaseline = 9.81;
  static const double _gravityAlpha = 0.9;

  // Synergy Boost: rung mạnh + âm thanh nguy hiểm trong cùng cửa sổ 1.5 giây
  static const Duration _synergyWindow = Duration(milliseconds: 1500);
  static const double _dangerSoundLevel = 0.7;
  DateTime? _lastStrongMotionAt;
  DateTime? _lastDangerSoundAt;
  double _lastDelta = 0.0;

  /// Độ lệch gia tốc gần nhất sau khi khử trọng lực (m/s²) — để hiển thị/debug.
  double get lastDelta => _lastDelta;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _startAccelerometer();
  }

  void stop() {
    _isRunning = false;
    _accelSub?.cancel();
    _accelSub = null;
  }

  void dispose() {
    stop();
    _soundSub?.cancel();
    _soundSub = null;
    _fusionController.close();
  }

  /// Lắng nghe trực tiếp kết quả YAMNet và cập nhật thành phần "sound".
  /// riskScore đã được SoundClassifierService tính theo trọng số nhóm âm thanh
  /// (kính vỡ/la hét = 1.0, gõ/cửa = 0.7, nhiễu nền = 0.0).
  void attachSoundClassifier(SoundClassifierService classifier) {
    _soundSub?.cancel();
    _soundSub = classifier.resultStream.listen((r) {
      updateSoundResult(r.label, r.riskScore);
    });
  }

  // ─── Accelerometer ─────────────────────────────────────────────────────────

  void _startAccelerometer() {
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen((event) {
      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      // Δa = |‖a‖ − g| với g là đường cơ sở trọng lực lọc thông thấp
      final delta = (magnitude - _gravityBaseline).abs();
      _gravityBaseline =
          _gravityAlpha * _gravityBaseline + (1 - _gravityAlpha) * magnitude;
      _lastDelta = delta;

      _motionScore = motionScoreFromDelta(delta, motionThreshold);
      if (delta >= motionThreshold) _lastStrongMotionAt = DateTime.now();

      _evaluate();
    }, onError: (_) {});
  }

  /// Ánh xạ Δa (m/s²) → điểm chuyển động theo bậc.
  /// Với [strong] = 3.5 (mặc định): tĩnh < 1.5, dao động nhẹ 1.5–3.5,
  /// rung mạnh/cạy cửa 3.5–7.0 (0.7→1.0), va đập ≥ 7.0 (1.0).
  static double motionScoreFromDelta(double delta, double strong) {
    final light = strong * (1.5 / 3.5);
    final severe = strong * 2.0;
    if (delta < light) return (delta / light) * 0.2;
    if (delta < strong) return 0.2 + (delta - light) / (strong - light) * 0.3;
    if (delta < severe) return 0.7 + (delta - strong) / (severe - strong) * 0.3;
    return 1.0;
  }

  bool _synergyActive(DateTime now) {
    final m = _lastStrongMotionAt;
    final s = _lastDangerSoundAt;
    if (m == null || s == null) return false;
    return now.difference(m) <= _synergyWindow &&
        now.difference(s) <= _synergyWindow &&
        m.difference(s).abs() <= _synergyWindow;
  }

  // ─── Evaluation ────────────────────────────────────────────────────────────

  void _evaluate() {
    // soundConfidence đã là điểm nguy cơ có trọng số (nhiễu nền ≈ 0)
    final effectiveSoundScore = soundConfidence;

    final weighted = _wMotion * _motionScore +
        _wSound  * effectiveSoundScore +
        _wVision * visionScore;

    // Kết hợp Weighted Synergy với Peak Detection:
    // Nếu chỉ 1 cảm biến phát hiện tín hiệu nguy hiểm cực mạnh (ví dụ kính vỡ 90%
    // khi điện thoại đặt cố định trên bàn, hoặc rung lắc mạnh trong phòng yên tĩnh),
    // điểm đơn lẻ cao vẫn vượt qua được triggerThreshold (0.65), đồng thời đa cảm biến
    // cùng kích hoạt sẽ đẩy điểm lên ngưỡng Critical nhanh hơn.
    final peak = max(_motionScore, max(effectiveSoundScore, visionScore));
    var fused = max(weighted, peak * 0.85 + weighted * 0.25).clamp(0.0, 1.0);

    // Synergy Boost: rung mạnh + âm thanh nguy hiểm trong 1.5 giây → Critical
    final synergy = _synergyActive(DateTime.now());
    if (synergy) fused = 1.0;

    final severity = _toSeverity(fused);
    final reason   = synergy
        ? 'Cộng hưởng: ${_buildReason()}'
        : _buildReason();

    final result = FusionResult(
      score: fused,
      level: severity,
      reason: reason,
      breakdown: {
        'motion': _motionScore,
        'sound':  effectiveSoundScore,
        'vision': visionScore,
      },
    );

    _fusionController.add(result);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  AlertSeverity _toSeverity(double score) {
    if (score >= 0.85) return AlertSeverity.critical;
    if (score >= triggerThreshold) return AlertSeverity.high;
    if (score >= 0.40) return AlertSeverity.medium;
    return AlertSeverity.low;
  }

  String _buildReason() {
    final parts = <String>[];
    if (_motionScore > 0.3) parts.add('Chuyển động bất thường');
    if (soundConfidence > 0.4) {
      parts.add('Âm thanh: ${SoundClassifierService.labelToVietnamese(soundLabel)} '
          '(${(soundConfidence * 100).toStringAsFixed(0)}%)');
    }
    if (visionScore > 0.3) parts.add('Phát hiện người lạ');
    return parts.isEmpty ? 'Bình thường' : parts.join(' • ');
  }

  /// Cập nhật điểm vision từ bên ngoài (CameraGuardScreen)
  void updateVisionScore(double score) {
    visionScore = score.clamp(0.0, 1.0);
    if (_isRunning) _evaluate();
  }

  /// Cập nhật kết quả phân loại âm thanh từ SoundClassifierService
  void updateSoundResult(String label, double confidence) {
    soundLabel = label;
    soundConfidence = confidence.clamp(0.0, 1.0);
    if (soundConfidence >= _dangerSoundLevel) _lastDangerSoundAt = DateTime.now();
    if (_isRunning) _evaluate();
  }
}

// ─── Alert Orchestrator ────────────────────────────────────────────────────
/// AlertOrchestrator — Điều phối toàn bộ chuỗi báo động khi cảm biến kích hoạt.
///
/// Chuỗi hành động:
///   1. Rung thiết bị (vibration)
///   2. Phát cảnh báo giọng nói TTS
///   3. Cập nhật thông báo Foreground Service
///   4. POST /api/alerts/trigger → Discord webhook
///   5. Gọi điện cho liên hệ khẩn cấp đầu tiên
///   6. SMS fallback (nếu có quyền)
class AlertOrchestrator {
  static bool _isDispatching = false;
  static DateTime? _lastDispatch;
  static const int _cooldownSeconds = 20;

  /// Dừng toàn bộ còi báo động, giọng nói TTS và rung ngay lập tức
  static Future<void> stopAllAlarms() async {
    _isDispatching = false;
    try {
      await TtsService.stop();
    } catch (_) {}
    try {
      if (!kIsWeb && Platform.isAndroid) {
        await Vibration.cancel();
      }
    } catch (_) {}
  }

  /// Kích hoạt chuỗi báo động đầy đủ.
  /// [postToServer] = false khi nơi gọi đã tự POST /api/alerts/trigger
  /// (ví dụ CameraGuardScreen gửi kèm ảnh) để tránh trùng tin Discord.
  /// [localFeedback] = false khi nơi gọi đã tự rung + đọc TTS.
  static Future<void> triggerFullAlert({
    required FusionResult fusion,
    required String deviceId,
    required String deviceName,
    bool postToServer = true,
    bool localFeedback = true,
  }) async {
    // Chặn gọi trùng trong cooldown
    final now = DateTime.now();
    if (_isDispatching) return;
    if (_lastDispatch != null &&
        now.difference(_lastDispatch!).inSeconds < _cooldownSeconds) {
      return;
    }

    _isDispatching = true;
    _lastDispatch = now;

    try {
      if (localFeedback) {
        // 1. Rung thiết bị
        if (!kIsWeb && Platform.isAndroid) {
          if (await Vibration.hasVibrator() == true) {
            Vibration.vibrate(pattern: [0, 400, 200, 400, 200, 800]);
          }
        }

        // 2. TTS cảnh báo
        await TtsService.speak(
          'Cảnh báo! Phát hiện xâm nhập tại $deviceName. '
          'Hệ thống đang thông báo người thân.',
        );
      }

      // 3. Foreground Service notification
      await ForegroundServiceController.notifyAlarm(
        title: '🚨 Cảnh báo xâm nhập!',
        message: fusion.reason,
      );

      // 4. POST báo động lên server → Discord Webhook
      if (postToServer) {
        await _postAlertToServer(fusion: fusion, deviceId: deviceId);
      }

      // 4b. Gửi dự phòng trực tiếp tới Discord Webhook đã lưu trên máy (nếu có)
      await _sendDirectDiscordIfConfigured(
        deviceName: deviceName,
        reason: fusion.reason,
        severity: fusion.level == AlertSeverity.critical ? 'Critical' : 'Warning',
      );

      // 5. Gọi điện khẩn cấp
      await _callEmergencyContacts(fusion: fusion);

    } catch (e) {
      debugPrint('[AlertOrchestrator] Error: $e');
    } finally {
      _isDispatching = false;
    }
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  static Future<void> _postAlertToServer({
    required FusionResult fusion,
    required String deviceId,
  }) async {
    final guid = RegExp(r'^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$');
    final validDeviceId = guid.hasMatch(deviceId)
        ? deviceId
        : '00000000-0000-0000-0000-000000000000';
    try {
      await ApiClient.request('POST', '/api/alerts/trigger', body: {
        'deviceId': validDeviceId,
        'triggerReason': fusion.breakdown['sound'] != null &&
                fusion.breakdown['sound']! >= (fusion.breakdown['motion'] ?? 0)
            ? 'TIENG_DONG'
            : 'CHUYEN_DONG',
        'triggerScore': fusion.score,
        'severity': fusion.level == AlertSeverity.critical ? 'Critical' : 'Warning',
      });
    } catch (e) {
      debugPrint('[AlertOrchestrator] POST alert failed: $e');
    }
  }

  static Future<void> _sendDirectDiscordIfConfigured({
    required String deviceName,
    required String reason,
    required String severity,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final webhookUrl = prefs.getString('sg_discord_webhook_url')?.trim() ?? '';
      if (webhookUrl.isEmpty || !webhookUrl.startsWith('http')) return;

      final now = DateTime.now();
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} '
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

      await http.post(
        Uri.parse(webhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': '🚨 **CẢNH BÁO AN NINH SMARTGUARD**: Thiết bị **$deviceName** phát hiện **$reason** lúc `$timeStr`!',
          'embeds': [
            {
              'title': '🚨 CẢNH BÁO PHÁT HIỆN XÂM NHẬP',
              'description':
                  '**Thiết bị:** $deviceName\n**Sự kiện:** $reason\n**Mức độ:** $severity\n**Thời gian (VN):** $timeStr',
              'color': severity == 'Critical' ? 16711680 : 16744448,
            }
          ]
        }),
      );
    } catch (_) {}
  }

  static Future<void> _callEmergencyContacts({
    required FusionResult fusion,
  }) async {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} '
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}';
    final smsText = 'SMARTGUARD CANH BAO: ${fusion.reason} luc $timeStr. '
        'Muc do: ${fusion.level == AlertSeverity.critical ? 'NGUY CAP' : 'CAO'}. '
        'Vui long kiem tra ngay!';

    try {
      final info = await EmergencyService.dispatchEmergencyAlert(reason: fusion.reason);
      final smsList = (info['smsList'] as List).cast<EmergencyContactModel>();
      final sentTo = <String>{};

      // SMS tới các liên hệ bật nhận tin nhắn (không chặn luồng gọi)
      for (final c in smsList) {
        final phone = c.phone.trim();
        if (sentTo.add(phone)) {
          await ForegroundServiceController.sendSms(phone, smsText);
        }
      }

      // Gọi điện trực tiếp qua SIM tới liên hệ ưu tiên số 1
      final primary = await EmergencyService.getPrimaryCallContact();
      if (primary != null && primary.phone.trim().isNotEmpty) {
        final phone = primary.phone.trim();
        final called = await ForegroundServiceController.callEmergency(phone);
        // Fallback cấp 3: cuộc gọi thất bại → gửi SMS cho chính người đó
        if (!called && sentTo.add(phone)) {
          await ForegroundServiceController.sendSms(phone, smsText);
        }
      }
    } catch (e) {
      debugPrint('[AlertOrchestrator] Emergency dispatch failed: $e');
    }
  }
}
