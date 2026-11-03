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
  double _lastAccelMagnitude = 9.8; // gravity baseline

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
      // Delta từ lần đọc trước (loại bỏ trọng lực tĩnh)
      final delta = (magnitude - _lastAccelMagnitude).abs();
      _lastAccelMagnitude = magnitude;

      // Chuẩn hoá delta: 0 → 0.0, motionThreshold → 1.0
      _motionScore = (delta / motionThreshold).clamp(0.0, 1.0);

      _evaluate();
    }, onError: (_) {});
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
    final fused = max(weighted, peak * 0.85 + weighted * 0.25).clamp(0.0, 1.0);

    final severity = _toSeverity(fused);
    final reason   = _buildReason();

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
    try {
      final primary = await EmergencyService.getPrimaryCallContact();
      if (primary != null && primary.phone.trim().isNotEmpty) {
        await ForegroundServiceController.callEmergency(
          primary.phone.trim(),
        );
      }
    } catch (e) {
      debugPrint('[AlertOrchestrator] Emergency dispatch failed: $e');
    }
  }
}
