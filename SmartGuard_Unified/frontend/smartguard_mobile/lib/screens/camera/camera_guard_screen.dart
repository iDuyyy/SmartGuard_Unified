import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:intl/intl.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../models/models.dart';
import '../../services/tts_service.dart';
import '../../services/sensor_fusion_service.dart';
import '../alerts/alerts_history_screen.dart';

class CameraGuardScreen extends StatefulWidget {
  final bool isTab;
  const CameraGuardScreen({super.key, this.isTab = false});

  @override
  State<CameraGuardScreen> createState() => _CameraGuardScreenState();
}

class _CameraGuardScreenState extends State<CameraGuardScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  bool _isCameraReady = false;
  bool _isProcessingFrame = false;

  // Cho phép Bật / Tắt canh gác Camera & Cảm biến trực tiếp
  bool _isGuardEnabled = true;
  DateTime? _lastAlertTime;
  final int _cooldownSeconds = 15;

  DateTime? _snoozeUntil;
  String? _activeAlertId;
  bool _isAlarmActive = false;
  Timer? _alertPollTimer;

  StreamSubscription<AccelerometerEvent>? _sensorSubscription;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: false,
      enableClassification: false,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  List<DeviceModel> _devices = [];
  String? _selectedDeviceId;
  String _statusText = 'Đang khởi tạo camera...';
  Color _statusColor = AppTheme.statusArmed;

  bool _hasPersonInFrame = false;
  List<KnownPersonModel> _knownPersons = [];
  final bool _autoDismissForKnownPersons = true;
  DateTime? _lastKnownPersonNotice;

  bool _isMuted = false;
  bool _isIntercomActive = false;
  bool _isFullscreen = false;

  // Danh sách cảnh báo thật từ máy chủ + đường dẫn ảnh cục bộ vừa chụp
  List<AlertModel> _recentAlerts = [];
  final Map<String, String> _localPhotoByAlertId = {};
  String? _latestLocalPhotoPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _alertPollTimer?.cancel();
    _sensorSubscription?.cancel();
    _cameraController?.dispose();
    _faceDetector.close();
    TtsService.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initSystem() async {
    final prefs = await SharedPreferences.getInstance();
    final savedGuard = prefs.getBool('sg_guard_monitoring_enabled') ?? true;
    if (mounted) {
      setState(() {
        _isGuardEnabled = savedGuard;
      });
    }
    await _loadDevices();
    await _loadKnownPersons();
    await _loadRecentAlerts();
    await _initCamera();
    _initAccelerometer();
  }

  Future<void> _toggleGuardMonitoring(bool enabled) async {
    setState(() {
      _isGuardEnabled = enabled;
      if (!enabled) {
        _isAlarmActive = false;
        _statusText = 'Đã tắt cảm biến & canh gác';
        _statusColor = AppTheme.statusWarning;
      } else {
        _statusText = 'Đang canh gác trực tiếp';
        _statusColor = AppTheme.statusArmed;
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sg_guard_monitoring_enabled', enabled);

    if (!enabled) {
      await AlertOrchestrator.stopAllAlarms();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? '🛡️ Đã BẬT canh gác Camera & Cảm biến rung lắc!'
                : '🔕 Đã TẮT cảm biến & dừng mọi cảnh báo!',
          ),
          backgroundColor: enabled ? AppTheme.statusArmed : AppTheme.statusWarning,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadRecentAlerts() async {
    try {
      final res = await ApiClient.request('GET', '/api/alerts/history?limit=15') as List<dynamic>;
      if (mounted) {
        setState(() {
          _recentAlerts = res
              .map((e) => AlertModel.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _loadDevices() async {
    try {
      final res = await ApiClient.request('GET', '/api/devices') as List<dynamic>;
      final list = res.map((e) => DeviceModel.fromJson(e as Map<String, dynamic>)).toList();
      if (list.isEmpty) {
        try {
          final newDev = await ApiClient.request('POST', '/api/devices', body: {
            'name': 'Camera Cửa Chính',
            'description': 'Camera AI giám sát nhận diện khuôn mặt',
            'noiseThreshold': 70.0,
            'motionThreshold': 3.5,
          });
          if (newDev is Map<String, dynamic>) {
            list.add(DeviceModel.fromJson(newDev));
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _devices = list;
          if (list.isNotEmpty) {
            _selectedDeviceId = list.first.id;
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _initCamera() async {
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        setState(() => _statusText = 'Không tìm thấy camera trên thiết bị.');
        return;
      }

      final camera = _cameras[_selectedCameraIndex];
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraReady = true;
        _statusText = _isGuardEnabled ? 'Đang canh gác trực tiếp' : 'Đã tắt cảm biến & canh gác';
        _statusColor = _isGuardEnabled ? AppTheme.statusArmed : AppTheme.statusWarning;
      });

      await _cameraController!.startImageStream(_processCameraFrame);
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = 'Chế độ mô phỏng trực tiếp';
          _statusColor = AppTheme.statusArmed;
        });
      }
    }
  }

  void _switchCamera() async {
    if (_cameras.length < 2) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _cameraController?.dispose();
    setState(() => _isCameraReady = false);
    await _initCamera();
  }

  /// Chụp ảnh an toàn: tạm dừng ImageStream trên Android trước khi gọi takePicture()
  Future<File?> _captureSnapshotSafely() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || controller.value.isTakingPicture) {
      return null;
    }
    final wasStreaming = controller.value.isStreamingImages;
    try {
      if (wasStreaming) {
        await controller.stopImageStream();
      }
      final xFile = await controller.takePicture();
      final file = File(xFile.path);
      if (file.existsSync()) {
        _latestLocalPhotoPath = file.path;
        return file;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (wasStreaming && mounted && controller.value.isInitialized && !controller.value.isStreamingImages) {
        try {
          await controller.startImageStream(_processCameraFrame);
        } catch (_) {}
      }
    }
  }

  Future<void> _takeSnapshot() async {
    final snapFile = await _captureSnapshotSafely();
    if (snapFile != null) {
      String? uploadedUrl;
      final devId = _selectedDeviceId ?? (_devices.isNotEmpty ? _devices.first.id : '');
      if (devId.isNotEmpty) {
        try {
          final uploadRes = await ApiClient.uploadFile(
            '/api/images/upload',
            snapFile,
            fields: {'deviceId': devId},
          );
          if (uploadRes is Map) {
            uploadedUrl = uploadRes['imageUrl']?.toString();
          }
        } catch (_) {}
      }
      if (mounted) {
        _showPhotoPreviewDialog(
          title: 'Ảnh chụp nhanh Camera',
          subtitle: DateFormat('HH:mm:ss • dd/MM/yyyy').format(DateTime.now()),
          localPath: snapFile.path,
          networkUrl: uploadedUrl,
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không thể chụp ảnh lúc này. Vui lòng chờ camera sẵn sàng.'),
            backgroundColor: AppTheme.statusWarning,
          ),
        );
      }
    }
  }

  Future<void> _loadKnownPersons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('sg_known_persons');
      if (str != null && str.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(str);
        if (mounted) {
          setState(() {
            _knownPersons = jsonList.map((e) => KnownPersonModel.fromJson(e as Map<String, dynamic>)).toList();
          });
        }
      }
    } catch (_) {}
  }

  void _initAccelerometer() {
    _sensorSubscription = accelerometerEventStream().listen((event) {
      if (!_isGuardEnabled) return;
      if (_snoozeUntil != null && DateTime.now().isBefore(_snoozeUntil!)) return;
      if (_hasPersonInFrame) return;

      final double magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final double delta = (magnitude - 9.8).abs();

      if (delta > 3.8) {
        _handleSecurityTrigger('PHAT_HIEN_RUNG_LAC', delta);
      }
    });
  }

  Future<void> _processCameraFrame(CameraImage image) async {
    if (_isProcessingFrame || !_isGuardEnabled) return;
    if (_snoozeUntil != null && DateTime.now().isBefore(_snoozeUntil!)) return;

    _isProcessingFrame = true;
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final camera = _cameras[_selectedCameraIndex];
      final imageRotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation) ?? InputImageRotation.rotation0deg;
      final inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

      final inputImageMetadata = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes.isNotEmpty ? image.planes.first.bytesPerRow : image.width,
      );

      final inputImage = InputImage.fromBytes(bytes: bytes, metadata: inputImageMetadata);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        _hasPersonInFrame = true;
        if (_autoDismissForKnownPersons && _knownPersons.isNotEmpty) {
          final now = DateTime.now();
          if (_lastKnownPersonNotice == null || now.difference(_lastKnownPersonNotice!).inSeconds > 10) {
            _lastKnownPersonNotice = now;
            if (!_isMuted) {
              TtsService.playWarningVoice('NGUOI_QUEN');
            }
          }
          if (mounted) {
            setState(() {
              _statusText = 'Nhận diện người quen (${_knownPersons.first.name})';
              _statusColor = AppTheme.statusArmed;
            });
          }
        } else {
          _handleSecurityTrigger('PHAT_HIEN_NGUOI_LA', faces.length.toDouble());
        }
      } else {
        _hasPersonInFrame = false;
        if (mounted && !_isAlarmActive && _isGuardEnabled) {
          setState(() {
            _statusText = 'Đang canh gác trực tiếp';
            _statusColor = AppTheme.statusArmed;
          });
        }
      }
    } catch (_) {} finally {
      _isProcessingFrame = false;
    }
  }

  String _formatReason(String code) {
    final upper = code.toUpperCase();
    if (upper.contains('NGUOI') || upper.contains('PERSON')) return 'Phát hiện người lạ trước camera';
    if (upper.contains('RUNG_LAC') || upper.contains('SHAKE')) return 'Phát hiện rung lắc thiết bị';
    if (upper.contains('CHUYEN_DONG') || upper.contains('MOTION')) return 'Phát hiện chuyển động';
    if (upper.contains('TIENG_DONG') || upper.contains('NOISE') || upper.contains('SOUND')) return 'Âm thanh bất thường';
    return code;
  }

  Future<void> _handleSecurityTrigger(String reason, double score) async {
    if (!_isGuardEnabled) return;
    final now = DateTime.now();
    if (_snoozeUntil != null && now.isBefore(_snoozeUntil!)) return;
    if (_lastAlertTime != null && now.difference(_lastAlertTime!).inSeconds < _cooldownSeconds) return;

    _lastAlertTime = now;
    if (mounted) {
      setState(() {
        _isAlarmActive = true;
        _statusText = 'CẢNH BÁO: ${_formatReason(reason)}!';
        _statusColor = AppTheme.statusAlarm;
      });
    }

    if (!_isMuted) {
      try {
        final hasVib = await Vibration.hasVibrator();
        if (hasVib == true) {
          Vibration.vibrate(pattern: [500, 1000, 500, 1000]);
        }
      } catch (_) {}

      TtsService.playWarningVoice(reason);
    }

    final devId = (_selectedDeviceId != null && _selectedDeviceId!.isNotEmpty)
        ? _selectedDeviceId!
        : (_devices.isNotEmpty ? _devices.first.id : '00000000-0000-0000-0000-000000000000');
    final devName = _devices.isNotEmpty ? _devices.first.name : 'Camera cửa chính';

    // 1. Chụp ảnh bằng chứng an toàn (tạm dừng stream trước khi chụp)
    String? imageUrl;
    String? localSnapPath;
    try {
      final snapFile = await _captureSnapshotSafely();
      if (snapFile != null && snapFile.existsSync()) {
        localSnapPath = snapFile.path;
        final uploadFields = <String, String>{};
        if (devId != '00000000-0000-0000-0000-000000000000') {
          uploadFields['deviceId'] = devId;
        }
        final uploadRes = await ApiClient.uploadFile(
          '/api/images/upload',
          snapFile,
          fields: uploadFields,
        );
        if (uploadRes is Map) {
          imageUrl = uploadRes['imageUrl']?.toString();
        }
      }
    } catch (_) {}

    // 2. Gửi cảnh báo kèm ảnh lên Backend -> lưu DB & bắn thông báo Discord
    String alertId = '';
    try {
      final alertRes = await ApiClient.request('POST', '/api/alerts/trigger', body: {
        'deviceId': devId,
        'triggerReason': reason,
        'triggerScore': score,
        'severity': 'Critical',
        'imageUrl': imageUrl,
      });
      if (alertRes is Map<String, dynamic>) {
        alertId = (alertRes['alertId'] ?? alertRes['id'])?.toString() ?? '';
        _activeAlertId = alertId;
        if (alertId.isNotEmpty && localSnapPath != null) {
          _localPhotoByAlertId[alertId] = localSnapPath;
        }
      }
    } catch (_) {}

    // 3. Làm mới danh sách sự kiện bên dưới ngay lập tức
    await _loadRecentAlerts();

    // 4. Gọi điện khẩn cấp tới người thân ưu tiên số 1
    AlertOrchestrator.triggerFullAlert(
      fusion: FusionResult(
        score: (score / 10).clamp(0.0, 1.0),
        level: AlertSeverity.high,
        reason: _formatReason(reason),
        breakdown: {'motion': score / 10, 'sound': 0.0, 'vision': 1.0},
      ),
      deviceId: devId,
      deviceName: devName,
      postToServer: false,
      localFeedback: false,
    );

    _startAlertStatusPolling(alertId);
  }

  void _startAlertStatusPolling(String? alertId) {
    _alertPollTimer?.cancel();
    int checkCount = 0;
    final devId = _selectedDeviceId ?? (_devices.isNotEmpty ? _devices.first.id : null);
    if (devId == null) return;

    _alertPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      checkCount++;
      if (checkCount > 45 || !_isAlarmActive) {
        timer.cancel();
        return;
      }
      try {
        final statusRes = await ApiClient.request('GET', '/api/alerts/device/$devId/status');
        if (statusRes is Map<String, dynamic>) {
          final isSnoozed = statusRes['isSnoozed'] == true;
          final latest = statusRes['latestAlert'];
          if (latest is Map<String, dynamic>) {
            final st = latest['status']?.toString();
            if (st == 'KnownPerson') {
              _dismissAlarm(isKnownPerson: true, fromRemote: true);
              timer.cancel();
            } else if (st == 'Muted') {
              _dismissAlarm(isMuted: true, fromRemote: true);
              timer.cancel();
            } else if (st == 'Dismissed') {
              _dismissAlarm(fromRemote: true);
              timer.cancel();
            }
          } else if (isSnoozed) {
            _dismissAlarm(isKnownPerson: true, fromRemote: true);
            timer.cancel();
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _dismissAlarm({bool isKnownPerson = false, bool isMuted = false, bool fromRemote = false}) async {
    _alertPollTimer?.cancel();
    _alertPollTimer = null;
    await AlertOrchestrator.stopAllAlarms();

    final now = DateTime.now();
    if (isKnownPerson) {
      _snoozeUntil = now.add(const Duration(minutes: 3));
      if (!_isMuted) {
        TtsService.playWarningVoice('NGUOI_QUEN');
      }
      if (mounted) {
        setState(() {
          _isAlarmActive = false;
          _statusText = fromRemote
              ? '✅ Người quen (Discord) - Tạm dừng 3 phút'
              : '✅ Đã xác nhận Người quen - Tạm dừng 3 phút';
          _statusColor = AppTheme.statusArmed;
        });
      }
    } else if (isMuted) {
      _snoozeUntil = now.add(const Duration(minutes: 3));
      if (mounted) {
        setState(() {
          _isAlarmActive = false;
          _statusText = fromRemote
              ? '🔕 Đã tắt chuông (Discord) - Tạm dừng 3 phút'
              : '🔕 Đã tắt còi báo động - Tạm dừng 3 phút';
          _statusColor = AppTheme.statusArmed;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isAlarmActive = false;
          _statusText = _isGuardEnabled ? 'Đang canh gác trực tiếp' : 'Đã tắt cảm biến & canh gác';
          _statusColor = _isGuardEnabled ? AppTheme.statusArmed : AppTheme.statusWarning;
        });
      }
    }

    if (!fromRemote && _activeAlertId != null && _activeAlertId!.isNotEmpty) {
      try {
        final actionStr = isKnownPerson ? 'KnownPerson' : (isMuted ? 'Mute' : 'Dismiss');
        await ApiClient.request('POST', '/api/alerts/$_activeAlertId/action', body: {'action': actionStr});
        await _loadRecentAlerts();
      } catch (_) {}
    }
  }

  void _showPhotoPreviewDialog({
    required String title,
    required String subtitle,
    String? localPath,
    String? networkUrl,
    AlertModel? alert,
  }) {
    final hasLocal = localPath != null && localPath.isNotEmpty && File(localPath).existsSync();
    final hasNet = networkUrl != null && networkUrl.isNotEmpty && !networkUrl.contains('sample_alert.jpg');
    final fullNetUrl = hasNet
        ? (networkUrl.startsWith('http') ? networkUrl : '${AppConfig.baseUrl}$networkUrl')
        : null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardWhite,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            const Icon(Icons.photo_camera_back_rounded, color: AppTheme.coralPink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: hasLocal
                    ? Image.file(
                        File(localPath),
                        height: 240,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      )
                    : (fullNetUrl != null
                        ? Image.network(
                            fullNetUrl,
                            height: 240,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 160,
                              width: double.infinity,
                              color: AppTheme.creamBg,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.asset('assets/images/alter.png', height: 64),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Ảnh này không còn lưu trên máy chủ Cloud',
                                    style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Container(
                            height: 150,
                            width: double.infinity,
                            color: AppTheme.creamBg,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Image.asset('assets/images/alter.png', height: 64),
                                const SizedBox(height: 6),
                                const Text(
                                  'Sự kiện cảm biến (không kèm ảnh chụp)',
                                  style: TextStyle(fontSize: 12, color: AppTheme.secondaryText),
                                ),
                              ],
                            ),
                          )),
              ),
              const SizedBox(height: 12),
              Text('🕒 $subtitle', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.headingDark)),
              if (alert != null) ...[
                const SizedBox(height: 4),
                Text('📷 Thiết bị: ${alert.deviceName} • Trạng thái: ${alert.status}', style: const TextStyle(fontSize: 12, color: AppTheme.secondaryText)),
              ],
            ],
          ),
        ),
        actions: [
          if (alert != null)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _dismissAlarm(isMuted: true);
              },
              icon: const Icon(Icons.volume_off, size: 18, color: AppTheme.statusWarning),
              label: const Text('Tắt còi'),
            ),
          if (alert != null)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.statusArmed, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(ctx);
                _dismissAlarm(isKnownPerson: true);
              },
              icon: const Icon(Icons.verified_user, size: 18),
              label: const Text('Người quen'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Đóng'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devName = _devices.isNotEmpty ? _devices.first.name : 'Camera cửa chính';

    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar + Nút Bật/Tắt Cảm biến & Canh gác
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (!widget.isTab && Navigator.of(context).canPop())
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: AppTheme.headingDark),
                            onPressed: () => Navigator.pop(context),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppTheme.borderWarm),
                            ),
                            child: Icon(
                              _isGuardEnabled ? Icons.videocam : Icons.videocam_off,
                              color: _isGuardEnabled ? AppTheme.coralPink : AppTheme.secondaryText,
                              size: 20,
                            ),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                devName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.headingDark,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _statusText,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _statusColor,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Công tắc Bật / Tắt cảm biến & canh gác trực tiếp
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isGuardEnabled ? 'Đang bật' : 'Đã tắt',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _isGuardEnabled ? AppTheme.statusArmed : AppTheme.statusWarning,
                        ),
                      ),
                      Switch.adaptive(
                        value: _isGuardEnabled,
                        activeTrackColor: AppTheme.statusArmed,
                        onChanged: _toggleGuardMonitoring,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Video Streaming Card
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppTheme.borderWarm, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_isCameraReady && _cameraController != null)
                          CameraPreview(_cameraController!)
                        else
                          Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0xFF2B3A4A), Color(0xFF1E2836)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.asset(
                                    'assets/images/3bc65821-0388-43aa-aba6-16fc6a3912a4.png',
                                    height: 100,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.videocam_outlined,
                                      size: 64,
                                      color: Colors.white54,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Đang kết nối camera an ninh...',
                                    style: TextStyle(color: Colors.white70, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        Center(
                          child: Container(
                            width: 200,
                            height: 200,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _statusColor.withValues(alpha: 0.6),
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),

                        Positioned(
                          bottom: -6,
                          right: 8,
                          child: IgnorePointer(
                            child: Image.asset(
                              'assets/images/sticker_system(2).png',
                              height: 64,
                              errorBuilder: (_, __, ___) => Image.asset(
                                'assets/images/Capybara.jpg',
                                height: 60,
                                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),

                        // Alarm Active Banner overlay (có cả nút Tắt còi & Người quen)
                        if (_isAlarmActive)
                          Positioned(
                            top: 12,
                            left: 12,
                            right: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.coralPink.withValues(alpha: 0.96),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                                  const SizedBox(width: 6),
                                  const Expanded(
                                    child: Text(
                                      'CẢNH BÁO XÂM NHẬP!',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _dismissAlarm(isMuted: true),
                                    style: TextButton.styleFrom(
                                      backgroundColor: Colors.black26,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                    ),
                                    child: const Text(
                                      '🔕 Tắt còi',
                                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  TextButton(
                                    onPressed: () => _dismissAlarm(isKnownPerson: true),
                                    style: TextButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      minimumSize: Size.zero,
                                    ),
                                    child: const Text(
                                      '✅ Người quen',
                                      style: TextStyle(color: AppTheme.coralPink, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Rounded Floating Control Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2937),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    // Tắt còi / Âm thanh
                    IconButton(
                      icon: Icon(
                        _isMuted ? Icons.volume_off : Icons.volume_up,
                        color: _isMuted ? AppTheme.coralPink : Colors.white,
                      ),
                      tooltip: _isMuted ? 'Bật lại âm cảnh báo' : 'Tắt âm cảnh báo & còi hú',
                      onPressed: () async {
                        setState(() => _isMuted = !_isMuted);
                        if (_isMuted) {
                          await AlertOrchestrator.stopAllAlarms();
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(_isMuted ? '🔕 Đã tắt âm cảnh báo & dừng còi hú' : '🔊 Đã bật âm thanh cảnh báo'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                    ),
                    // Nút Bật/Tắt cảm biến nhanh trên thanh điều khiển
                    IconButton(
                      icon: Icon(
                        _isGuardEnabled ? Icons.sensors : Icons.sensors_off,
                        color: _isGuardEnabled ? AppTheme.statusArmed : Colors.white54,
                      ),
                      tooltip: _isGuardEnabled ? 'Tắt cảm biến' : 'Bật cảm biến',
                      onPressed: () => _toggleGuardMonitoring(!_isGuardEnabled),
                    ),
                    // Snapshot Camera Button
                    Container(
                      decoration: const BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt, color: Colors.white, size: 22),
                        tooltip: 'Chụp ảnh bằng chứng ngay',
                        onPressed: _takeSnapshot,
                      ),
                    ),
                    // Flip Camera / Switch
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                      tooltip: 'Đổi camera trước/sau',
                      onPressed: _switchCamera,
                    ),
                    // Xem ảnh vừa chụp gần nhất
                    IconButton(
                      icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
                      tooltip: 'Xem ảnh vừa chụp',
                      onPressed: () {
                        if (_latestLocalPhotoPath != null && File(_latestLocalPhotoPath!).existsSync()) {
                          _showPhotoPreviewDialog(
                            title: 'Ảnh chụp gần nhất trên máy',
                            subtitle: DateFormat('HH:mm:ss • dd/MM/yyyy').format(DateTime.now()),
                            localPath: _latestLocalPhotoPath,
                          );
                        } else if (_recentAlerts.isNotEmpty) {
                          final first = _recentAlerts.first;
                          _showPhotoPreviewDialog(
                            title: _formatReason(first.triggerReason),
                            subtitle: DateFormat('HH:mm:ss • dd/MM/yyyy').format(first.triggeredAt),
                            localPath: _localPhotoByAlertId[first.id],
                            networkUrl: first.imageUrl,
                            alert: first,
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Chưa có ảnh chụp nào. Hãy bấm nút máy ảnh ở giữa để chụp!')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Timeline Section "Sự kiện hôm nay (Chạm để xem ảnh)"
            Expanded(
              flex: 4,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x0A000000),
                      blurRadius: 10,
                      offset: Offset(0, -3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Text(
                              'Sự kiện gần đây (Chạm để xem ảnh)',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.headingDark,
                              ),
                            ),
                          ],
                        ),
                        InkWell(
                          onTap: _loadRecentAlerts,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.creamBg,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_recentAlerts.length} sự kiện ↻',
                              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Expanded(
                      child: _recentAlerts.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có cảnh báo nào hôm nay.',
                                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _recentAlerts.length,
                              separatorBuilder: (_, __) => const Divider(height: 10, color: AppTheme.borderWarm),
                              itemBuilder: (ctx, index) {
                                final alert = _recentAlerts[index];
                                final title = _formatReason(alert.triggerReason);
                                final timeStr = DateFormat('HH:mm').format(alert.triggeredAt.toLocal());
                                final dateStr = DateFormat('dd/MM').format(alert.triggeredAt.toLocal());
                                final subtitle = '${alert.deviceName} • $dateStr • ${alert.status}';
                                final localPhoto = _localPhotoByAlertId[alert.id];
                                final hasLocal = localPhoto != null && File(localPhoto).existsSync();
                                final imageUrl = alert.imageUrl;

                                return InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () {
                                    _showPhotoPreviewDialog(
                                      title: title,
                                      subtitle: DateFormat('HH:mm:ss • dd/MM/yyyy').format(alert.triggeredAt.toLocal()),
                                      localPath: localPhoto,
                                      networkUrl: imageUrl,
                                      alert: alert,
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 48,
                                          child: Text(
                                            timeStr,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: AppTheme.headingDark,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                title,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppTheme.headingDark,
                                                ),
                                              ),
                                              Text(
                                                subtitle,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppTheme.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Container(
                                            width: 48,
                                            height: 36,
                                            color: const Color(0xFFF1F5F9),
                                            child: hasLocal
                                                ? Image.file(File(localPhoto), fit: BoxFit.cover)
                                                : (imageUrl != null && imageUrl.isNotEmpty
                                                    ? Image.network(
                                                        imageUrl.startsWith('http')
                                                            ? imageUrl
                                                            : '${AppConfig.baseUrl}$imageUrl',
                                                        fit: BoxFit.cover,
                                                        errorBuilder: (_, __, ___) => _eventIconFor(title),
                                                      )
                                                    : _eventIconFor(title)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),

                    const SizedBox(height: 8),

                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: AppTheme.primaryGradient,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.coralPink.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const AlertsHistoryScreen()),
                            ).then((_) => _loadRecentAlerts());
                          },
                          child: const Text(
                            'Xem lịch sử đầy đủ',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _eventIconFor(String title) {
    final lower = title.toLowerCase();
    if (lower.contains('người') || lower.contains('stranger')) {
      return const Icon(Icons.person_pin_circle, color: AppTheme.coralPink, size: 20);
    } else if (lower.contains('chuyển động') || lower.contains('rung')) {
      return const Icon(Icons.directions_run, color: Color(0xFF10B981), size: 20);
    } else if (lower.contains('âm thanh') || lower.contains('sound')) {
      return const Icon(Icons.graphic_eq, color: AppTheme.royalPurple, size: 20);
    }
    return const Icon(Icons.shield_outlined, color: AppTheme.statusArmed, size: 20);
  }
}
