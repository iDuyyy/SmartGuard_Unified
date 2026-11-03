import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../models/models.dart';
import '../../services/sensor_fusion_service.dart';

class AlertsHistoryScreen extends StatefulWidget {
  final bool isTab;
  const AlertsHistoryScreen({super.key, this.isTab = false});

  @override
  State<AlertsHistoryScreen> createState() => AlertsHistoryScreenState();
}

class AlertsHistoryScreenState extends State<AlertsHistoryScreen> {
  bool _isLoading = true;
  List<AlertModel> _alerts = [];
  Timer? _autoRefreshTimer;

  String _selectedFilter = 'all'; // 'all', 'today', 'yesterday', '7days'
  String _searchQuery = '';
  bool _isSearchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();

  static const _cacheKey = 'sg_cached_alerts';

  @override
  void initState() {
    super.initState();
    _loadCachedAlerts();
    _loadAlerts();

    // Tự động làm mới dữ liệu định kỳ mỗi 8 giây khi đang xem màn hình
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) {
        _loadAlerts(isSilent: true);
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void reloadAlerts() {
    _loadCachedAlerts();
    _loadAlerts();
  }

  Future<void> _loadCachedAlerts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && cached.isNotEmpty && mounted) {
        final list = (jsonDecode(cached) as List<dynamic>)
            .map((e) => AlertModel.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() => _alerts = list);
      }
    } catch (_) {}
  }

  Future<void> _loadAlerts({bool isSilent = false}) async {
    if (!isSilent && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final res =
          await ApiClient.request('GET', '/api/alerts/history?limit=50')
              as List<dynamic>;
      final list = res
          .map((e) => AlertModel.fromJson(e as Map<String, dynamic>))
          .toList();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(res));

      if (mounted) {
        setState(() {
          _alerts = list;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _acknowledgeAlert(String id, String action) async {
    if (action != 'ConfirmedStranger') {
      await AlertOrchestrator.stopAllAlarms();
    }
    try {
      await ApiClient.request(
        'POST',
        '/api/alerts/$id/action',
        body: {'action': action},
      );
      if (!mounted) return;

      String actionMsg = 'Đã cập nhật trạng thái';
      if (action == 'KnownPerson') {
        actionMsg =
            '✅ Đã xác nhận Người quen - Hệ thống đã tắt báo động và tạm dừng cảnh báo 3 phút';
      } else if (action == 'ConfirmedStranger') {
        actionMsg = '🚨 Đã xác nhận Người lạ xâm nhập!';
      } else if (action == 'Dismiss') {
        actionMsg = 'Đã bỏ qua sự kiện cảnh báo.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(actionMsg),
          backgroundColor: action == 'ConfirmedStranger'
              ? AppTheme.statusAlarm
              : AppTheme.statusArmed,
          duration: const Duration(seconds: 3),
        ),
      );
      _loadAlerts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi: $e'),
          backgroundColor: AppTheme.statusAlarm,
        ),
      );
    }
  }

  void _showEvidenceDialog(AlertModel alert) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.shield_outlined, color: AppTheme.coralPink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                alert.triggerReason,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Thiết bị: ${alert.deviceName}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Thời gian: ${alert.triggeredAt.toLocal().toString().substring(0, 19)}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Trạng thái: ${_statusLabel(alert.status)}',
                style: TextStyle(
                  color: _statusColor(alert.status),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              if (alert.imageUrl != null && alert.imageUrl!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    alert.imageUrl!.startsWith('http')
                        ? alert.imageUrl!
                        : '${AppConfig.baseUrl}${alert.imageUrl}',
                    height: 210,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 120,
                      decoration: BoxDecoration(
                        color: AppTheme.creamBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text('Ảnh này không còn lưu trên máy chủ Cloud'),
                      ),
                    ),
                  ),
                )
              else
                Container(
                  height: 90,
                  decoration: BoxDecoration(
                    color: AppTheme.creamBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Text(
                      'Không có hình ảnh đính kèm',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _acknowledgeAlert(alert.id, 'Dismiss');
            },
            child: const Text(
              'Bỏ qua',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusArmed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _acknowledgeAlert(alert.id, 'KnownPerson');
            },
            icon: const Icon(Icons.check_circle_outline, size: 16),
            label: const Text('Người quen'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.coralPink,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _acknowledgeAlert(alert.id, 'ConfirmedStranger');
            },
            icon: const Icon(Icons.warning, size: 16),
            label: const Text('Người lạ'),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'KnownPerson':
        return 'Người quen';
      case 'ConfirmedStranger':
        return 'Người lạ';
      case 'Muted':
        return 'Đã tắt chuông';
      case 'Confirmed':
        return 'Đã duyệt';
      case 'Dismissed':
        return 'Đã bỏ qua';
      default:
        return 'Mới';
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'KnownPerson':
      case 'Confirmed':
        return AppTheme.statusArmed;
      case 'Dismissed':
      case 'Muted':
        return const Color(0xFF64748B);
      default:
        return AppTheme.coralPink;
    }
  }

  List<AlertModel> get _filteredAlerts {
    final now = DateTime.now();
    return _alerts.where((a) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final match =
            a.triggerReason.toLowerCase().contains(q) ||
            a.deviceName.toLowerCase().contains(q);
        if (!match) return false;
      }

      final date = a.triggeredAt.toLocal();
      if (_selectedFilter == 'today') {
        return date.year == now.year &&
            date.month == now.month &&
            date.day == now.day;
      } else if (_selectedFilter == 'yesterday') {
        final yesterday = now.subtract(const Duration(days: 1));
        return date.year == yesterday.year &&
            date.month == yesterday.month &&
            date.day == yesterday.day;
      } else if (_selectedFilter == '7days') {
        return now.difference(date).inDays <= 7;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar matching Mockup "LỊCH SỬ CẢNH BÁO"
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      if (!widget.isTab && Navigator.of(context).canPop())
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: AppTheme.textPrimary,
                          ),
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
                          child: const Icon(
                            Icons.access_time_filled,
                            color: AppTheme.coralPink,
                            size: 20,
                          ),
                        ),
                      const SizedBox(width: 10),
                      const Text(
                        'Lịch sử',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _isSearchOpen ? Icons.close : Icons.search,
                          color: AppTheme.textPrimary,
                        ),
                        onPressed: () {
                          setState(() {
                            _isSearchOpen = !_isSearchOpen;
                            if (!_isSearchOpen) {
                              _searchQuery = '';
                              _searchCtrl.clear();
                            }
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.refresh,
                          color: AppTheme.textPrimary,
                        ),
                        onPressed: () => _loadAlerts(),
                        tooltip: 'Làm mới',
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Search bar input (toggleable)
            if (_isSearchOpen)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Tìm sự kiện, tên camera...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(color: AppTheme.borderWarm),
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                ),
              ),

            // Filter Chips matching Mockup: [Tất cả], [Hôm nay], [Hôm qua], [7 ngày]
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  _buildFilterChip('Tất cả', 'all'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Hôm nay', 'today'),
                  const SizedBox(width: 8),
                  _buildFilterChip('Hôm qua', 'yesterday'),
                  const SizedBox(width: 8),
                  _buildFilterChip('7 ngày', '7days'),
                ],
              ),
            ),

            const SizedBox(height: 6),

            // Main List Section
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _loadAlerts(),
                child: _buildAlertsList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String key) {
    final isSelected = _selectedFilter == key;
    return GestureDetector(
      onTap: () => setState(() => _selectedFilter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF5B44BA) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF5B44BA) : AppTheme.borderWarm,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF5B44BA).withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : AppTheme.textSecondary,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildAlertsList() {
    if (_isLoading && _alerts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final displayList = _filteredAlerts;

    if (displayList.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/sticker_system(2).png',
                height: 120,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.shield_outlined,
                  size: 64,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Không có cảnh báo nào',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Mọi thứ đều an toàn và bình yên dưới sự bảo vệ của Capybara!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    // Nhóm theo ngày: Hôm nay, Hôm qua, hoặc ngày tháng
    final now = DateTime.now();
    final todayAlerts = <AlertModel>[];
    final yesterdayAlerts = <AlertModel>[];
    final earlierAlerts = <AlertModel>[];

    for (final a in displayList) {
      final date = a.triggeredAt.toLocal();
      if (date.year == now.year &&
          date.month == now.month &&
          date.day == now.day) {
        todayAlerts.add(a);
      } else if (date.year == now.year &&
          date.month == now.month &&
          date.day == now.day - 1) {
        yesterdayAlerts.add(a);
      } else {
        earlierAlerts.add(a);
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (todayAlerts.isNotEmpty) ...[
          _buildGroupHeader('Hôm nay - ${_formatHeaderDate(now)}'),
          ...todayAlerts.map((a) => _buildAlertCard(a)),
          const SizedBox(height: 12),
        ],
        if (yesterdayAlerts.isNotEmpty) ...[
          _buildGroupHeader(
            'Hôm qua - ${_formatHeaderDate(now.subtract(const Duration(days: 1)))}',
          ),
          ...yesterdayAlerts.map((a) => _buildAlertCard(a)),
          const SizedBox(height: 12),
        ],
        if (earlierAlerts.isNotEmpty) ...[
          _buildGroupHeader('Các ngày trước'),
          ...earlierAlerts.map((a) => _buildAlertCard(a)),
          const SizedBox(height: 12),
        ],

        // Cute Capybara postman illustration at the bottom of the history list (from mockup!)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Column(
              children: [
                Image.asset(
                  'assets/images/sticker_system(2).png',
                  height: 90,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Capybara luôn túc trực bảo vệ 24/7 🐾',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  String _formatHeaderDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d/$m/${dt.year}';
  }

  Widget _buildAlertCard(AlertModel alert) {
    final iconData = _iconForAlert(alert.triggerReason);
    final iconBgColor = _iconBgForAlert(alert.triggerReason);
    final iconColor = _iconColorForAlert(alert.triggerReason);
    final timeStr = alert.triggeredAt.toLocal().toString().substring(11, 16);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderWarm),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showEvidenceDialog(alert),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Event colored circular icon
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(iconData, color: iconColor, size: 22),
                ),
                const SizedBox(width: 12),

                // Event info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _friendlyReason(alert.triggerReason),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            alert.deviceName.isNotEmpty
                                ? alert.deviceName
                                : 'Camera cửa chính',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            '•',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            timeStr,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Right thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 52,
                    height: 42,
                    color: const Color(0xFFF1F5F9),
                    child: alert.imageUrl != null && alert.imageUrl!.isNotEmpty
                        ? Image.network(
                            '${AppConfig.baseUrl}${alert.imageUrl}',
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                Icon(iconData, color: iconColor, size: 20),
                          )
                        : Icon(iconData, color: iconColor, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _friendlyReason(String raw) {
    if (raw.contains('PHAT_HIEN_NGUOI_LA') ||
        raw.toLowerCase().contains('stranger')) {
      return 'Phát hiện người lạ';
    } else if (raw.contains('RUNG_LAC') ||
        raw.toLowerCase().contains('motion')) {
      return 'Phát hiện chuyển động';
    } else if (raw.contains('AM_THANH') ||
        raw.toLowerCase().contains('sound')) {
      return 'Âm thanh bất thường';
    } else if (raw.contains('KHOI_DONG') ||
        raw.toLowerCase().contains('system')) {
      return 'Hệ thống khởi động';
    }
    return raw;
  }

  IconData _iconForAlert(String reason) {
    if (reason.contains('NGUOI_LA') ||
        reason.toLowerCase().contains('stranger')) {
      return Icons.person_pin_circle;
    } else if (reason.contains('RUNG_LAC') ||
        reason.toLowerCase().contains('motion')) {
      return Icons.directions_run;
    } else if (reason.contains('AM_THANH') ||
        reason.toLowerCase().contains('sound')) {
      return Icons.graphic_eq;
    }
    return Icons.settings_power;
  }

  Color _iconColorForAlert(String reason) {
    if (reason.contains('NGUOI_LA') ||
        reason.toLowerCase().contains('stranger')) {
      return AppTheme.coralPink;
    } else if (reason.contains('RUNG_LAC') ||
        reason.toLowerCase().contains('motion')) {
      return const Color(0xFF10B981);
    } else if (reason.contains('AM_THANH') ||
        reason.toLowerCase().contains('sound')) {
      return AppTheme.royalPurple;
    }
    return const Color(0xFF3B82F6);
  }

  Color _iconBgForAlert(String reason) {
    if (reason.contains('NGUOI_LA') ||
        reason.toLowerCase().contains('stranger')) {
      return const Color(0xFFFFECE8);
    } else if (reason.contains('RUNG_LAC') ||
        reason.toLowerCase().contains('motion')) {
      return const Color(0xFFE8F5E9);
    } else if (reason.contains('AM_THANH') ||
        reason.toLowerCase().contains('sound')) {
      return const Color(0xFFF3E8FF);
    }
    return const Color(0xFFEFF6FF);
  }
}
