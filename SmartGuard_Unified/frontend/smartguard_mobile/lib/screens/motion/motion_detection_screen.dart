import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../services/sound_classifier_service.dart';
import '../../services/sensor_fusion_service.dart';
import '../../services/foreground_service_controller.dart';
import '../../widgets/battery_exemption_prompt.dart';

class MotionDetectionScreen extends StatefulWidget {
  final bool isTab;
  const MotionDetectionScreen({super.key, this.isTab = false});

  @override
  State<MotionDetectionScreen> createState() => _MotionDetectionScreenState();
}

class _MotionDetectionScreenState extends State<MotionDetectionScreen>
    with SingleTickerProviderStateMixin {
  // ─── State ─────────────────────────────────────────────────────────────────
  bool _isMonitoringActive = false;
  double _motionSensitivity = 3.5; // m/s² delta threshold
  double _soundThreshold = 0.65; // 0.0–1.0
  double _fusionThreshold = 0.65; // combined score trigger

  double _currentMotionScore = 0.0;
  double _currentSoundScore = 0.0;
  String _currentSoundLabel = 'Silence';
  double _fusedScore = 0.0;
  AlertSeverity _severity = AlertSeverity.low;

  String _activeDeviceId = '';
  String _activeDeviceName = 'Thiết bị cảm biến';

  final List<_MotionEvent> _eventHistory = [];

  // Services
  late SensorFusionService _fusion;
  late SoundClassifierService _sound;

  StreamSubscription<FusionResult>? _fusionSub;
  StreamSubscription<SoundClassificationResult>? _soundSub;
  StreamSubscription<double>? _ampSub;
  StreamSubscription<AccelerometerEvent>? _rawAccelSub;

  // Waveform animation
  late AnimationController _waveController;
  final List<double> _waveform = List.generate(30, (_) => 0.5);
  Timer? _waveTimer;

  // Pref key
  static const String _prefMotion = 'sg_motion_sensitivity';
  static const String _prefSound = 'sg_sound_threshold';
  static const String _prefFusion = 'sg_fusion_threshold';
  static const String _prefActive = 'sg_motion_active';

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _fusion = SensorFusionService();
    _sound = SoundClassifierService();
    _loadPrefs();
    _loadActiveDevice();
  }

  Future<void> _loadActiveDevice() async {
    try {
      final list = await ApiClient.request('GET', '/api/devices') as List<dynamic>;
      if (list.isNotEmpty && mounted) {
        final firstArmed = list.firstWhere(
          (d) => d['isArmed'] == true,
          orElse: () => list.first,
        );
        setState(() {
          _activeDeviceId = firstArmed['id']?.toString() ?? '';
          _activeDeviceName = firstArmed['name']?.toString() ?? 'Thiết bị cảm biến';
        });
      }
    } catch (_) {
      // Offline hoặc chưa đăng nhập -> vẫn chạy cảnh báo local bình thường
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    _waveTimer?.cancel();
    _stopMonitoring();
    _fusion.dispose();
    _sound.dispose();
    super.dispose();
  }

  // ─── Prefs ─────────────────────────────────────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _motionSensitivity = prefs.getDouble(_prefMotion) ?? 3.5;
      _soundThreshold = prefs.getDouble(_prefSound) ?? 0.65;
      _fusionThreshold = prefs.getDouble(_prefFusion) ?? 0.65;
      _isMonitoringActive = prefs.getBool(_prefActive) ?? false;
    });
    if (_isMonitoringActive) _startMonitoring();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefMotion, _motionSensitivity);
    await prefs.setDouble(_prefSound, _soundThreshold);
    await prefs.setDouble(_prefFusion, _fusionThreshold);
    await prefs.setBool(_prefActive, _isMonitoringActive);
  }

  // ─── Monitoring ────────────────────────────────────────────────────────────
  Future<void> _startMonitoring() async {
    await _loadActiveDevice();
    _fusion.motionThreshold = _motionSensitivity;
    _fusion.triggerThreshold = _fusionThreshold;
    _sound.confidenceThreshold = _soundThreshold;

    // YAMNet → SensorFusion (dùng riskScore có trọng số)
    _fusion.attachSoundClassifier(_sound);
    _soundSub = _sound.resultStream.listen((r) {
      if (!mounted) return;
      setState(() {
        _currentSoundScore = r.riskScore;
        _currentSoundLabel = r.label;
      });
    });
    // Sóng âm thật từ mức RMS của micro
    _ampSub = _sound.amplitudeStream.listen(_updateWaveform);

    // Fusion results
    _fusionSub = _fusion.fusionStream.listen((r) {
      if (!mounted) return;
      setState(() {
        _currentMotionScore = r.breakdown['motion'] ?? 0.0;
        _fusedScore = r.score;
        _severity = r.level;
      });

      if (r.level == AlertSeverity.high || r.level == AlertSeverity.critical) {
        _recordEvent(r);
        AlertOrchestrator.triggerFullAlert(
          fusion: r,
          deviceId: _activeDeviceId,
          deviceName: _activeDeviceName,
        );
      }
    });

    _fusion.start();
    await _sound.start();

    // Start foreground service for persistent background monitoring
    await ForegroundServiceController.startService();
  }

  void _stopMonitoring() {
    _fusionSub?.cancel();
    _soundSub?.cancel();
    _ampSub?.cancel();
    _rawAccelSub?.cancel();
    _fusionSub = null;
    _soundSub = null;
    _ampSub = null;
    _fusion.stop();
    _sound.stop();
    _waveTimer?.cancel();
    ForegroundServiceController.stopService();
  }

  void _toggleMonitoring() {
    setState(() => _isMonitoringActive = !_isMonitoringActive);
    if (_isMonitoringActive) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
    _savePrefs();
  }

  // ─── Waveform ──────────────────────────────────────────────────────────────
  // Nhận mức âm lượng thật (0..1) từ micro; throttle ~10 khung/giây để nhẹ UI
  DateTime _lastWaveUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  void _updateWaveform(double level) {
    final now = DateTime.now();
    if (now.difference(_lastWaveUpdate).inMilliseconds < 100) return;
    _lastWaveUpdate = now;
    if (!mounted) return;
    setState(() {
      _waveform.removeAt(0);
      _waveform.add(level);
    });
  }

  // ─── Event logging ─────────────────────────────────────────────────────────
  void _recordEvent(FusionResult r) {
    setState(() {
      _eventHistory.insert(
        0,
        _MotionEvent(
          time: DateTime.now(),
          label: r.reason,
          score: r.score,
          level: r.level,
        ),
      );
      if (_eventHistory.length > 50) _eventHistory.removeLast();
    });
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      appBar: widget.isTab
          ? null
          : AppBar(
              title: const Text('Phát hiện chuyển động'),
              backgroundColor: AppTheme.creamBg,
              leading: const BackButton(color: AppTheme.headingDark),
            ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isTab) _buildTabHeader(),
            const BatteryStatusCard(),
            _buildMasterToggle(),
            const SizedBox(height: 16),
            _buildSensorMetrics(),
            const SizedBox(height: 16),
            _buildAiStatus(),
            _buildSoundWaveform(),
            const SizedBox(height: 16),
            _buildSensitivitySettings(),
            const SizedBox(height: 16),
            _buildEventHistory(),
          ],
        ),
      ),
    );
  }

  // ─── Sub-widgets ───────────────────────────────────────────────────────────

  /// Trạng thái mô hình YAMNet – hiển thị rõ khi thiếu model / thiếu quyền mic
  Widget _buildAiStatus() {
    return ValueListenableBuilder<SoundAiStatus>(
      valueListenable: _sound.status,
      builder: (context, status, _) {
        Widget? leading;
        String? text;
        Color color = AppTheme.royalPurple;
        switch (status) {
          case SoundAiStatus.loading:
            leading = const SpinKitWave(color: AppTheme.royalPurple, size: 18);
            text = 'Đang tải mô hình AI âm thanh YAMNet...';
            break;
          case SoundAiStatus.modelMissing:
            leading = const Icon(
              Icons.error_outline,
              color: AppTheme.statusAlarm,
              size: 20,
            );
            text =
                'Thiếu mô hình: thêm assets/models/yamnet.tflite và '
                'yamnet_class_map.csv rồi build lại. AI âm thanh đang tắt.';
            color = AppTheme.statusAlarm;
            break;
          case SoundAiStatus.noPermission:
            leading = const Icon(
              Icons.mic_off,
              color: AppTheme.statusWarning,
              size: 20,
            );
            text = 'Chưa có quyền micro – hãy cấp quyền ghi âm cho SmartGuard.';
            color = AppTheme.statusWarning;
            break;
          case SoundAiStatus.error:
            leading = const Icon(
              Icons.warning_amber,
              color: AppTheme.statusAlarm,
              size: 20,
            );
            text = 'Lỗi micro: ${_sound.lastError ?? 'không xác định'}';
            color = AppTheme.statusAlarm;
            break;
          case SoundAiStatus.listening:
          case SoundAiStatus.idle:
            return const SizedBox.shrink();
        }
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              SizedBox(width: 24, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.textDark,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTabHeader() {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Row(
        children: [
          Image.asset(
            'assets/images/sticker_system(4).png',
            height: 48,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.sensors, size: 48, color: AppTheme.coralPink),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Phát hiện chuyển động',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.headingDark,
                ),
              ),
              Text(
                'AI cảm biến đa lớp thông minh',
                style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMasterToggle() {
    final color = _isMonitoringActive
        ? (_severity == AlertSeverity.critical ||
                  _severity == AlertSeverity.high
              ? AppTheme.statusAlarm
              : AppTheme.statusArmed)
        : AppTheme.secondaryText;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              _isMonitoringActive ? Icons.sensors : Icons.sensors_off,
              color: color,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isMonitoringActive ? 'Đang theo dõi' : 'Tắt theo dõi',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                Text(
                  _isMonitoringActive
                      ? _severity == AlertSeverity.low
                            ? 'Môi trường bình thường ✅'
                            : 'Cảnh báo: ${_severityLabel(_severity)}'
                      : 'Bật để kích hoạt AI cảm biến',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _isMonitoringActive,
            onChanged: (_) => _toggleMonitoring(),
            activeTrackColor: AppTheme.coralPink,
          ),
        ],
      ),
    );
  }

  Widget _buildSensorMetrics() {
    return Row(
      children: [
        Expanded(
          child: _metricCard(
            icon: Icons.vibration,
            label: 'Chuyển động',
            value: '${(_currentMotionScore * 100).toStringAsFixed(0)}%',
            color: _currentMotionScore > 0.6
                ? AppTheme.statusAlarm
                : AppTheme.statusArmed,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _metricCard(
            icon: Icons.hearing,
            label: SoundClassifierService.labelToVietnamese(_currentSoundLabel),
            value: '${(_currentSoundScore * 100).toStringAsFixed(0)}%',
            color: _currentSoundScore > 0.5
                ? AppTheme.statusWarning
                : AppTheme.statusArmed,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _metricCard(
            icon: Icons.merge_type,
            label: 'Điểm AI',
            value: '${(_fusedScore * 100).toStringAsFixed(0)}%',
            color: _fusedScore >= _fusionThreshold
                ? AppTheme.statusAlarm
                : AppTheme.statusArmed,
          ),
        ),
      ],
    );
  }

  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardWhite,
        border: Border.all(color: color.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.06), blurRadius: 8),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppTheme.secondaryText),
            textAlign: TextAlign.center,
            maxLines: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildSoundWaveform() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.graphic_eq,
                color: AppTheme.royalPurple,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Sóng âm thanh',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.headingDark,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.royalPurple.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  SoundClassifierService.labelToVietnamese(_currentSoundLabel),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.royalPurple,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(_waveform.length, (i) {
                final amplitude = _isMonitoringActive ? _waveform[i] : 0.05;
                final barColor = amplitude > 0.65
                    ? AppTheme.statusAlarm
                    : amplitude > 0.4
                    ? AppTheme.statusWarning
                    : AppTheme.royalPurple.withValues(alpha: 0.4);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: max(4, amplitude * 56),
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensitivitySettings() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, color: AppTheme.securityBlue, size: 18),
              SizedBox(width: 8),
              Text(
                'Cấu hình nhận diện',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.headingDark,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Motion sensitivity
          _sliderTile(
            label: 'Độ nhạy chuyển động',
            value: _motionSensitivity,
            min: 1.0,
            max: 8.0,
            displayText: '${_motionSensitivity.toStringAsFixed(1)} m/s²',
            icon: Icons.vibration,
            color: AppTheme.coralPink,
            onChanged: (v) {
              setState(() => _motionSensitivity = v);
              _fusion.motionThreshold = v;
              _savePrefs();
            },
          ),

          const SizedBox(height: 12),

          // Sound threshold
          _sliderTile(
            label: 'Ngưỡng nhận diện âm thanh',
            value: _soundThreshold,
            min: 0.3,
            max: 0.95,
            displayText: '${(_soundThreshold * 100).toStringAsFixed(0)}%',
            icon: Icons.hearing,
            color: AppTheme.royalPurple,
            onChanged: (v) {
              setState(() => _soundThreshold = v);
              _sound.updateThreshold(v);
              _savePrefs();
            },
          ),

          const SizedBox(height: 12),

          // Fusion threshold
          _sliderTile(
            label: 'Ngưỡng kích hoạt cảnh báo (AI)',
            value: _fusionThreshold,
            min: 0.4,
            max: 0.9,
            displayText: '${(_fusionThreshold * 100).toStringAsFixed(0)}%',
            icon: Icons.security,
            color: AppTheme.statusArmed,
            onChanged: (v) {
              setState(() => _fusionThreshold = v);
              _fusion.triggerThreshold = v;
              _savePrefs();
            },
          ),
        ],
      ),
    );
  }

  Widget _sliderTile({
    required String label,
    required double value,
    required double min,
    required double max,
    required String displayText,
    required IconData icon,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textDark,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                displayText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor: color,
            inactiveTrackColor: color.withValues(alpha: 0.15),
            thumbColor: color,
            overlayColor: color.withValues(alpha: 0.12),
          ),
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }

  Widget _buildEventHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Lịch sử sự kiện',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppTheme.headingDark,
              ),
            ),
            if (_eventHistory.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _eventHistory.clear()),
                icon: const Icon(Icons.clear_all, size: 16),
                label: const Text('Xóa tất cả'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.secondaryText,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        if (_eventHistory.isEmpty)
          _buildEmptyState()
        else
          ...(_eventHistory.take(20).map((e) => _buildEventTile(e))),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Column(
        children: [
          Image.asset(
            'assets/images/sticker_bao_an.png',
            height: 72,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.verified_user_outlined,
              size: 56,
              color: AppTheme.statusArmed,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Môi trường bình thường',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.headingDark,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Capybara đang canh gác. Chưa có sự kiện nào.',
            style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTile(_MotionEvent e) {
    final color = e.level == AlertSeverity.critical
        ? AppTheme.statusAlarm
        : e.level == AlertSeverity.high
        ? AppTheme.statusWarning
        : AppTheme.statusArmed;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.warning_amber_rounded, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.headingDark,
                  ),
                  maxLines: 2,
                ),
                Text(
                  'Điểm AI: ${(e.score * 100).toStringAsFixed(0)}% • '
                  '${_formatTime(e.time)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _severityLabel(e.level),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────
  String _severityLabel(AlertSeverity s) {
    switch (s) {
      case AlertSeverity.critical:
        return 'Nguy hiểm';
      case AlertSeverity.high:
        return 'Cảnh báo';
      case AlertSeverity.medium:
        return 'Theo dõi';
      case AlertSeverity.low:
        return 'Bình thường';
    }
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s trước';
    if (diff.inMinutes < 60) return '${diff.inMinutes} phút trước';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

// ─── Data model ───────────────────────────────────────────────────────────────
class _MotionEvent {
  final DateTime time;
  final String label;
  final double score;
  final AlertSeverity level;

  _MotionEvent({
    required this.time,
    required this.label,
    required this.score,
    required this.level,
  });
}
