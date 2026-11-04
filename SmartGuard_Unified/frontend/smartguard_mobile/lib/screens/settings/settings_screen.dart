import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../core/session_manager.dart';
import '../../services/auth_service.dart';
import '../admin/admin_screen.dart';
import '../auth/welcome_screen.dart';
import '../camera/camera_guard_screen.dart';
import '../members/members_screen.dart';
import '../motion/motion_detection_screen.dart';
import '../zones/zones_screen.dart';
import '../../widgets/battery_exemption_prompt.dart';

class SettingsScreen extends StatefulWidget {
  final bool isTab;
  final bool isModal;
  const SettingsScreen({super.key, this.isTab = false, this.isModal = false});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _serverController = TextEditingController();
  bool _testingConnection = false;
  String? _testResult;
  bool _testSuccess = false;

  String _username = 'Người bảo vệ';
  String _email = 'user@smartguard.local';
  bool _isAdmin = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _serverController.text = AppConfig.baseUrl;
    _loadUserInfo();
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _loadUserInfo() async {
    final user = await SessionManager.getCurrentUser();
    final bioEnabled = await SessionManager.isBiometricLinkedToCurrentUser();
    if (mounted) {
      setState(() {
        if (user != null) {
          _username = user.username.isNotEmpty ? user.username : 'Chủ nhà';
          _email = user.email.isNotEmpty ? user.email : 'Chưa cập nhật email';
          _isAdmin = user.role.toLowerCase() == 'admin';
        }
        _biometricEnabled = bioEnabled;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value) {
      if (!SessionManager.isLoggedIn) {
        _showSnack('Vui lòng đăng nhập trước khi bật vân tay.', AppTheme.statusWarning);
        return;
      }
      final canBio = await AuthService.canUseBiometric();
      if (!canBio) {
        _showSnack('Thiết bị không hỗ trợ hoặc chưa đăng ký sinh trắc học.', AppTheme.statusAlarm);
        return;
      }
      final auth = await AuthService.authenticateBiometric(
        reason: 'Quét vân tay để liên kết với tài khoản $_email',
      );
      if (!auth.success) {
        if (!auth.busy) {
          _showSnack(auth.message ?? 'Xác thực vân tay thất bại.', AppTheme.statusWarning);
        }
        return;
      }
      final ok = await SessionManager.enableBiometricForCurrentUser();
      if (!ok) {
        _showSnack('Không lưu được liên kết vân tay. Vui lòng đăng nhập lại rồi thử lại.', AppTheme.statusAlarm);
        return;
      }
      if (mounted) setState(() => _biometricEnabled = true);
      _showSnack('Đã bật đăng nhập vân tay cho tài khoản $_email', AppTheme.statusArmed);
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Tắt đăng nhập vân tay'),
          content: const Text(
            'Liên kết vân tay của tài khoản này sẽ bị xóa khỏi thiết bị. '
            'Lần sau bạn phải đăng nhập bằng mật khẩu. Tiếp tục?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.coralPink),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Tắt vân tay', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      await AuthService.unlinkBiometric();
      if (mounted) setState(() => _biometricEnabled = false);
      _showSnack('Đã xóa liên kết đăng nhập vân tay trên thiết bị này.', AppTheme.statusArmed);
    }
  }

  void _showSnack(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: color),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testingConnection = true;
      _testResult = null;
    });

    final targetUrl = _serverController.text.trim();
    final check = await ApiClient.testConnectionDetailed(targetUrl);

    if (mounted) {
      setState(() {
        _testingConnection = false;
        _testSuccess = check.ok;
        _serverController.text = check.url;
        _testResult = check.message;
      });
    }
  }

  Future<void> _saveServerUrl() async {
    final targetUrl = _serverController.text.trim();
    if (targetUrl.isEmpty) return;

    await AppConfig.setBaseUrl(targetUrl);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Đã lưu địa chỉ máy chủ mới'),
          backgroundColor: AppTheme.statusArmed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  Future<void> _showDiscordConfigDialog() async {
    final prefs = await SharedPreferences.getInstance();
    String currentWebhook = prefs.getString('sg_discord_webhook_url') ?? '';

    try {
      final res = await ApiClient.request('GET', '/api/alerts/discord-config');
      if (res is Map && res['webhookUrl'] != null && res['webhookUrl'].toString().isNotEmpty) {
        currentWebhook = res['webhookUrl'].toString();
      }
    } catch (_) {}

    final webhookCtrl = TextEditingController(text: currentWebhook);
    bool isTesting = false;
    String? statusMsg;
    bool statusOk = false;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.notifications_active_outlined, color: AppTheme.royalPurple),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Cấu hình & Gửi thử Discord',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Dán đường dẫn Discord Webhook của kênh thông báo (Cài đặt kênh Discord → Tích hợp → Webhooks → Sao chép URL Webhook):',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: webhookCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Discord Webhook URL',
                    hintText: 'https://discord.com/api/webhooks/...',
                    prefixIcon: const Icon(Icons.link),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                if (statusMsg != null)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: statusOk ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      statusMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusOk ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Đóng'),
            ),
            OutlinedButton.icon(
              icon: isTesting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded, size: 16),
              label: const Text('Gửi thử ngay'),
              onPressed: isTesting
                  ? null
                  : () async {
                      final url = webhookCtrl.text.trim();
                      if (url.isEmpty || !url.startsWith('http')) {
                        setDlg(() {
                          statusOk = false;
                          statusMsg = 'Vui lòng dán đường dẫn Discord Webhook hợp lệ.';
                        });
                        return;
                      }
                      setDlg(() {
                        isTesting = true;
                        statusMsg = null;
                      });

                      await prefs.setString('sg_discord_webhook_url', url);

                      // 1. Thử đồng bộ lên Backend trước
                      try {
                        await ApiClient.request('POST', '/api/alerts/discord-config', body: {'webhookUrl': url});
                      } catch (_) {}

                      // 2. Gửi trực tiếp tới Discord Webhook để kiểm tra ngay tức thì
                      try {
                        final now = DateTime.now();
                        final timeStr =
                            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')} '
                            '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
                        final res = await http.post(
                          Uri.parse(url),
                          headers: {'Content-Type': 'application/json'},
                          body: jsonEncode({
                            'content': '✅ **KIỂM TRA THÔNG BÁO DISCORD SMARTGUARD** lúc `$timeStr` (Giờ Việt Nam)!',
                            'embeds': [
                              {
                                'title': '🛡️ KẾT NỐI DISCORD THÀNH CÔNG',
                                'description':
                                    'Ứng dụng **SmartGuard Mobile** của tài khoản **$_username ($_email)** đã liên kết thành công với kênh Discord này!',
                                'color': 3066993,
                              }
                            ]
                          }),
                        );
                        if (res.statusCode >= 200 && res.statusCode < 300) {
                          setDlg(() {
                            isTesting = false;
                            statusOk = true;
                            statusMsg = '✅ Đã gửi tin nhắn thử nghiệm lên kênh Discord thành công! Hãy mở Discord kiểm tra.';
                          });
                        } else {
                          setDlg(() {
                            isTesting = false;
                            statusOk = false;
                            statusMsg =
                                '❌ Discord từ chối Webhook (HTTP ${res.statusCode}). Webhook cũ có thể đã bị Discord tự động khóa khi đẩy lên GitHub. Hãy tạo Webhook mới trong kênh Discord và dán vào đây!';
                          });
                        }
                      } catch (e) {
                        setDlg(() {
                          isTesting = false;
                          statusOk = false;
                          statusMsg = 'Lỗi kết nối: $e';
                        });
                      }
                    },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.royalPurple, foregroundColor: Colors.white),
              onPressed: () async {
                final url = webhookCtrl.text.trim();
                await prefs.setString('sg_discord_webhook_url', url);
                try {
                  await ApiClient.request('POST', '/api/alerts/discord-config', body: {'webhookUrl': url});
                } catch (_) {}
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã lưu cấu hình Discord Webhook!'),
                      backgroundColor: AppTheme.statusArmed,
                    ),
                  );
                }
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  void _showServerConfigDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.dns, color: AppTheme.coralPink),
              SizedBox(width: 8),
              Text('Cấu hình Máy chủ', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Thiết lập địa chỉ API của máy trạm để ứng dụng di động kết nối qua mạng LAN hoặc Cloud.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serverController,
                  decoration: InputDecoration(
                    labelText: 'Địa chỉ Base URL',
                    prefixIcon: const Icon(Icons.link),
                    hintText: 'https://smartguard-unified.onrender.com',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('Render Cloud'),
                      onPressed: () => setDlgState(() => _serverController.text = AppConfig.defaultCloudUrl),
                    ),
                    ActionChip(
                      label: const Text('Localhost (5235)'),
                      onPressed: () => setDlgState(() => _serverController.text = AppConfig.localhostUrl),
                    ),
                    ActionChip(
                      label: const Text('Máy ảo (10.0.2.2)'),
                      onPressed: () => setDlgState(() => _serverController.text = AppConfig.emulatorUrl),
                    ),
                    ActionChip(
                      label: const Text('LAN mẫu'),
                      onPressed: () => setDlgState(() => _serverController.text = AppConfig.defaultLanUrl),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_testResult != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _testSuccess ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testSuccess ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Đóng', style: TextStyle(color: AppTheme.textSecondary)),
            ),
            OutlinedButton(
              onPressed: () async {
                await _testConnection();
                setDlgState(() {});
              },
              child: _testingConnection
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Kiểm tra'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.coralPink,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                await _saveServerUrl();
                if (mounted) Navigator.pop(ctx);
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.logout, color: AppTheme.coralPink),
            SizedBox(width: 8),
            Text('Đăng xuất'),
          ],
        ),
        content: Text(
          _biometricEnabled
              ? 'Bạn có chắc chắn muốn đăng xuất? Liên kết vân tay vẫn được giữ, lần sau bạn có thể đăng nhập lại bằng vân tay.'
              : 'Bạn có chắc chắn muốn đăng xuất khỏi SmartGuard?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy', style: TextStyle(color: AppTheme.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.coralPink),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Đăng xuất', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AuthService.logout();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (route) => false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        if (!widget.isTab && Navigator.of(context).canPop())
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
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
                            child: const Icon(Icons.settings, color: AppTheme.coralPink, size: 20),
                          ),
                        const SizedBox(width: 10),
                        const Text(
                          'Cài đặt',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Image.asset(
                      'assets/images/sticker_system.png',
                      height: 52,
                      errorBuilder: (_, __, ___) => Image.asset(
                        'assets/images/3bc65821-0388-43aa-aba6-16fc6a3912a4.png',
                        height: 48,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 6),

              // Group 1: Account Info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.borderWarm),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: _isAdmin ? const Color(0xFFEDE9FE) : const Color(0xFFFFECE8),
                        child: Text(
                          _username.isNotEmpty ? _username[0].toUpperCase() : 'U',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: _isAdmin ? AppTheme.royalPurple : AppTheme.coralPink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    _username,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _isAdmin ? const Color(0xFFEDE9FE) : const Color(0xFFE0F2FE),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _isAdmin ? 'Quản trị viên' : 'Chủ nhà',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: _isAdmin ? AppTheme.royalPurple : const Color(0xFF0284C7),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _email,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Group 2: Core Settings Menu Cards
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppTheme.borderWarm),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _buildMenuItem(
                        icon: Icons.notifications_active_outlined,
                        iconColor: const Color(0xFFF59E0B),
                        title: 'Cấu hình & Gửi thử Thông báo Discord',
                        onTap: _showDiscordConfigDialog,
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.shield_outlined,
                        iconColor: const Color(0xFF10B981),
                        title: 'Cài đặt bảo vệ (AI Âm thanh & Cảm biến)',
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const MotionDetectionScreen()));
                        },
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.battery_saver_rounded,
                        iconColor: const Color(0xFFF59E0B),
                        title: 'Chạy nền & Miễn tối ưu pin (Doze Mode)',
                        onTap: () => BatteryExemptionPrompt.show(context),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.videocam_outlined,
                        iconColor: AppTheme.coralPink,
                        title: 'Camera & Cảm biến',
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const CameraGuardScreen()));
                        },
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.devices_outlined,
                        iconColor: AppTheme.royalPurple,
                        title: 'Thiết bị & Khu vực trong nhà',
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const ZonesScreen()));
                        },
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.people_outline,
                        iconColor: AppTheme.coralPink,
                        title: 'Người thân khẩn cấp & Chia sẻ Camera',
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const MembersScreen()));
                        },
                      ),

                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.admin_panel_settings,
                        iconColor: const Color(0xFF7C3AED),
                        title: 'Quản trị hệ thống & Phân quyền (Admin)',
                        badge: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'RBAC',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF7C3AED),
                            ),
                          ),
                        ),
                        onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminScreen()));
                        },
                      ),

                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.fingerprint,
                        iconColor: AppTheme.primaryNavy,
                        title: 'Đăng nhập bằng Vân tay / Face ID',
                        badge: Switch(
                          value: _biometricEnabled,
                          activeColor: AppTheme.royalPurple,
                          onChanged: _toggleBiometric,
                        ),
                        onTap: () => _toggleBiometric(!_biometricEnabled),
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.dns_outlined,
                        iconColor: const Color(0xFF64748B),
                        title: 'Cấu hình Máy chủ & IP',
                        onTap: _showServerConfigDialog,
                      ),
                      _buildDivider(),
                      _buildMenuItem(
                        icon: Icons.logout,
                        iconColor: AppTheme.coralPink,
                        title: 'Đăng xuất',
                        titleColor: AppTheme.coralPink,
                        onTap: _logout,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/images/save.png',
                      height: 50,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'SmartGuard Unified • Capybara Security Mascot',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    Color? titleColor,
    Widget? badge,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: titleColor ?? AppTheme.textPrimary,
                  ),
                ),
              ),
              if (badge != null) ...[
                badge,
                const SizedBox(width: 8),
              ],
              const Icon(Icons.arrow_forward_ios, size: 14, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, thickness: 1, color: AppTheme.borderWarm, indent: 52);
  }
}
