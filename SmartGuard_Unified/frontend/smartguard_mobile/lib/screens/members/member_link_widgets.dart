import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/app_theme.dart';
import '../../models/models.dart';
import '../../services/member_service.dart';

// ═══════════════════════════ MÃ QR CỦA TÔI ═══════════════════════════

Future<void> showMyQrSheet(BuildContext context) {
  final email = MemberService.myEmail;
  final name = MemberService.myName;

  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: const BoxDecoration(
        color: AppTheme.creamBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + MediaQuery.of(ctx).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SheetHandle(),
          const SizedBox(height: 14),
          const Text(
            'Mã QR liên kết của tôi',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 4),
          const Text(
            'Người thân mở SmartGuard → Thành viên → Chia sẻ camera → "Quét mã QR" để lấy Gmail của bạn.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 18),
          if (email.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Không tìm thấy Gmail của tài khoản đang đăng nhập. Hãy đăng xuất và đăng nhập lại.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.statusAlarm, fontWeight: FontWeight.w600),
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppTheme.borderWarm, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.royalPurple.withValues(alpha: 0.10),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: QrImageView(
                data: MemberQrPayload.encode(email, name),
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppTheme.primaryNavy),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: AppTheme.primaryNavy,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderWarm),
              ),
              child: Row(
                children: [
                  const Icon(Icons.alternate_email, color: AppTheme.coralPink, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (name.isNotEmpty)
                          Text(name, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                        Text(email, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Sao chép Gmail',
                    icon: const Icon(Icons.copy_rounded, size: 20, color: AppTheme.primaryNavy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: email));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Đã sao chép Gmail')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.verified_user_outlined, size: 16, color: AppTheme.statusArmed),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'QR chỉ chứa Gmail và tên hiển thị, không chứa mật khẩu hay mã đăng nhập.',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

// ═══════════════════════════ QUÉT QR ═══════════════════════════

class MemberQrScanScreen extends StatefulWidget {
  const MemberQrScanScreen({super.key});

  @override
  State<MemberQrScanScreen> createState() => _MemberQrScanScreenState();
}

class _MemberQrScanScreenState extends State<MemberQrScanScreen> {
  bool _handled = false;
  String? _hint;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final code in capture.barcodes) {
      final payload = MemberQrPayload.decode(code.rawValue);
      if (payload != null) {
        _handled = true;
        Navigator.of(context).pop(payload);
        return;
      }
    }
    if (mounted && _hint == null) {
      setState(() => _hint = 'Mã QR này không phải mã liên kết SmartGuard.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Quét mã QR liên kết', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(onDetect: _onDetect),
          // Khung ngắm
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.coralPink, width: 3),
                borderRadius: BorderRadius.circular(28),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _hint ?? 'Đưa mã QR "liên kết của tôi" trên máy kia vào khung để lấy Gmail tự động.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _hint != null ? AppTheme.statusWarning : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════ CHỌN QUYỀN ═══════════════════════════

class PermissionChoice {
  final String? deviceId; // null = tất cả thiết bị
  final bool canAcknowledge;
  const PermissionChoice(this.deviceId, this.canAcknowledge);
}

/// Bảng chọn quyền cho Member (chỉ Owner mở được).
/// Chỉ hiển thị những quyền backend THẬT SỰ hỗ trợ: phạm vi thiết bị + tắt chuông/xác nhận cảnh báo.
Future<PermissionChoice?> showPermissionSheet(
  BuildContext context, {
  required String title,
  required String memberEmail,
  required List<DeviceModel> devices,
  String? initialDeviceId,
  bool initialCanAck = true,
  String confirmLabel = 'Lưu quyền',
}) {
  String? deviceId = devices.any((d) => d.id == initialDeviceId) ? initialDeviceId : null;
  bool canAck = initialCanAck;

  return showModalBottomSheet<PermissionChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.creamBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.of(ctx).padding.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: _SheetHandle()),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(memberEmail, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 16),

              const _SectionLabel(icon: Icons.videocam_outlined, text: 'Quyền xem camera'),
              const SizedBox(height: 8),
              _ScopeTile(
                selected: deviceId == null,
                title: 'Tất cả thiết bị',
                subtitle: 'Xem mọi camera / cảm biến hiện có và thêm sau này',
                onTap: () => setSheet(() => deviceId = null),
              ),
              ...devices.map((d) => _ScopeTile(
                    selected: deviceId == d.id,
                    title: d.name,
                    subtitle: d.location.isNotEmpty ? 'Chỉ thiết bị này • ${d.location}' : 'Chỉ thiết bị này',
                    onTap: () => setSheet(() => deviceId = d.id),
                  )),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(
                    'Không tải được danh sách thiết bị, sẽ cấp quyền cho tất cả thiết bị.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ),
              const SizedBox(height: 14),

              const _SectionLabel(icon: Icons.notifications_active_outlined, text: 'Cảnh báo'),
              const SizedBox(height: 4),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderWarm),
                ),
                child: Column(
                  children: [
                    const ListTile(
                      dense: true,
                      leading: Icon(Icons.notifications_none_rounded, color: AppTheme.statusArmed),
                      title: Text('Nhận & xem lịch sử cảnh báo', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text('Luôn bật cho thiết bị được chia sẻ (backend quy định)', style: TextStyle(fontSize: 11)),
                      trailing: Icon(Icons.lock_outline, size: 18, color: AppTheme.textSecondary),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      dense: true,
                      secondary: const Icon(Icons.notifications_off_outlined, color: AppTheme.coralPink),
                      title: const Text('Tắt chuông, xác nhận cảnh báo & bật/tắt canh gác',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      value: canAck,
                      activeColor: AppTheme.coralPink,
                      onChanged: (v) => setSheet(() => canAck = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.statusWarningBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Quyền truy cập từng chức năng khác (cài đặt, vùng, thành viên…) chưa có trên backend nên chưa thể cấp riêng.',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF92400E)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Hủy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.coralPink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.pop(ctx, PermissionChoice(deviceId, canAck)),
                      child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════ WIDGET NHỎ ═══════════════════════════

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(color: AppTheme.borderSoft, borderRadius: BorderRadius.circular(3)),
      );
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionLabel({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.primaryNavy),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primaryNavy)),
        ],
      );
}

class _ScopeTile extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ScopeTile({required this.selected, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFF1EC) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? AppTheme.coralPink : AppTheme.borderWarm, width: selected ? 1.6 : 1),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppTheme.coralPink : AppTheme.textSecondary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                    Text(subtitle, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
