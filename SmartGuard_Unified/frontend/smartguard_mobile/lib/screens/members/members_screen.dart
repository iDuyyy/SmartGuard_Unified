import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../models/models.dart';
import '../../services/emergency_service.dart';
import '../../services/foreground_service_controller.dart';
import '../../services/member_service.dart';
import 'member_link_widgets.dart';

class MembersScreen extends StatefulWidget {
  final bool isTab;
  const MembersScreen({super.key, this.isTab = false});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _isLoading = true;
  List<EmergencyContactModel> _contacts = [];
  List<MemberModel> _sharedMembers = [];

  // Liên kết thành viên
  List<MemberLinkRequest> _incomingRequests = [];
  String? _requestsUnsupported; // backend chưa có API yêu cầu liên kết
  SharedWithMeResult? _sharedWithMe;
  String? _membersError;
  String? _sharedWithMeError;
  List<DeviceModel> _myDevices = [];

  final List<String> _relationshipOptions = [
    'Chủ nhà',
    'Vợ / Chồng',
    'Bố / Mẹ',
    'Con cái',
    'Anh / Chị / Em',
    'Hàng xóm thân thiết',
    'Bảo vệ tòa nhà',
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging && mounted) setState(() {});
    });
    _loadData();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    await _loadEmergencyContacts();
    await _loadSharedMembers();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadEmergencyContacts() async {
    final list = await EmergencyService.getContacts();
    if (mounted) {
      setState(() => _contacts = list);
    }
  }

  Future<void> _loadSharedMembers() async {
    List<MemberModel>? members;
    String? membersErr;
    try {
      members = await MemberService.getMyMembers();
    } catch (e) {
      membersErr = '$e';
    }

    List<MemberLinkRequest> requests = [];
    String? requestsUnsupported;
    try {
      requests = await MemberService.getIncomingRequests();
    } catch (e) {
      requestsUnsupported = '$e';
    }

    SharedWithMeResult? shared;
    String? sharedErr;
    try {
      shared = await MemberService.getSharedWithMe();
    } catch (e) {
      sharedErr = '$e';
    }

    List<DeviceModel> devices = _myDevices;
    try {
      devices = await MemberService.getMyOwnedDevices();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      if (members != null) _sharedMembers = members;
      _membersError = membersErr;
      _incomingRequests = requests;
      _requestsUnsupported = requestsUnsupported;
      _sharedWithMe = shared;
      _sharedWithMeError = sharedErr;
      _myDevices = devices;
    });
  }

  Future<void> _showAddContactDialog() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String rel = 'Bố / Mẹ';
    bool callAlert = true;
    bool smsAlert = true;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.person_add_alt_1, color: AppTheme.coralPink),
              SizedBox(width: 8),
              Text('Thêm Người Thân Khẩn Cấp', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Người thân mới thêm sẽ được đặt lên đầu danh sách làm Số ưu tiên gọi khẩn cấp #1 khi phát hiện đột nhập.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Họ và tên *',
                    hintText: 'Ví dụ: Bác Tuấn, Bố Hùng...',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Số điện thoại khẩn cấp *',
                    hintText: '0912 345 678',
                    prefixIcon: const Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: rel,
                  decoration: InputDecoration(
                    labelText: 'Mối quan hệ',
                    prefixIcon: const Icon(Icons.favorite_border),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  items: _relationshipOptions.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                  onChanged: (val) {
                    if (val != null) setDialogState(() => rel = val);
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tự động gọi điện khi có sự cố', style: TextStyle(fontSize: 13)),
                  value: callAlert,
                  activeColor: AppTheme.coralPink,
                  onChanged: (val) => setDialogState(() => callAlert = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tự động gửi SMS vị trí & ảnh', style: TextStyle(fontSize: 13)),
                  value: smsAlert,
                  activeColor: AppTheme.coralPink,
                  onChanged: (val) => setDialogState(() => smsAlert = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy', style: TextStyle(color: AppTheme.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.coralPink,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final phone = phoneCtrl.text.trim();
                if (name.isEmpty || phone.isEmpty) return;

                Navigator.pop(ctx);
                final newContact = EmergencyContactModel(
                  id: 'contact_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  phone: phone,
                  relationship: rel,
                  isCallAlert: callAlert,
                  isSmsAlert: smsAlert,
                );

                await EmergencyService.addContact(newContact);
                await _loadEmergencyContacts();

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Đã thêm $name ($phone) làm số gọi khẩn cấp ưu tiên #1!'),
                      backgroundColor: AppTheme.statusArmed,
                    ),
                  );
                }
              },
              child: const Text('Lưu người thân'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteContact(EmergencyContactModel c) async {
    await EmergencyService.deleteContact(c.id);
    await _loadEmergencyContacts();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã xóa ${c.name} khỏi danh sách khẩn cấp'),
          backgroundColor: AppTheme.textSecondary,
        ),
      );
    }
  }

  Future<void> _setPrimaryContact(EmergencyContactModel c) async {
    await EmergencyService.setPrimaryContact(c.id);
    await _loadEmergencyContacts();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⭐ Đã đặt ${c.name} (${c.phone}) làm số gọi khẩn cấp ưu tiên #1!'),
          backgroundColor: AppTheme.statusArmed,
        ),
      );
    }
  }

  Future<void> _testEmergencyAlert(EmergencyContactModel c) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📞 Đang gọi điện khẩn cấp tới ${c.name} (${c.phone})...'),
        backgroundColor: AppTheme.statusArmed,
        duration: const Duration(seconds: 2),
      ),
    );
    await ForegroundServiceController.callEmergency(c.phone);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      body: SafeArea(
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
                          child: const Icon(Icons.people_alt_outlined, color: AppTheme.coralPink, size: 20),
                        ),
                      const SizedBox(width: 10),
                      const Text(
                        'Thành viên',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: AppTheme.textPrimary),
                    onPressed: _loadData,
                    tooltip: 'Làm mới',
                  ),
                ],
              ),
            ),

            TabBar(
              controller: _tabCtrl,
              indicatorColor: AppTheme.coralPink,
              labelColor: AppTheme.coralPink,
              unselectedLabelColor: AppTheme.textSecondary,
              tabs: [
                Tab(
                  icon: const Icon(Icons.emergency_share),
                  text: 'Người thân khẩn cấp (${_contacts.length})',
                ),
                Tab(
                  icon: const Icon(Icons.app_registration),
                  text: 'Chia sẻ camera (${_sharedMembers.length + (_sharedWithMe?.owners.length ?? 0)})',
                ),
              ],
            ),

            const SizedBox(height: 8),

            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _buildEmergencyContactsTab(),
                  _buildSharedMembersTab(),
                ],
              ),
            ),

            if (_tabCtrl.index == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Image.asset(
                'assets/images/create_accout.png',
                height: 70,
                errorBuilder: (_, __, ___) => Image.asset(
                  'assets/images/Capybara.jpg',
                  height: 60,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.coralPink.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    ),
                    onPressed: _tabCtrl.index == 1 ? _scanQr : _showAddContactDialog,
                    icon: Icon(_tabCtrl.index == 1 ? Icons.qr_code_scanner : Icons.person_add, color: Colors.white),
                    label: Text(
                      _tabCtrl.index == 1 ? 'Quét mã QR để liên kết' : '+ Thêm người thân khẩn cấp',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyContactsTab() {
    if (_isLoading && _contacts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_contacts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/save.png',
                height: 100,
                errorBuilder: (_, __, ___) => const Icon(Icons.contact_phone_outlined, size: 64, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              const Text(
                'Chưa có danh bạ khẩn cấp',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              const Text(
                'Thêm số điện thoại người thân để hệ thống tự động gọi điện ngay khi phát hiện đột nhập hoặc rung lắc mạnh.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      itemCount: _contacts.length,
      itemBuilder: (ctx, index) {
        final c = _contacts[index];
        final isOwner = c.relationship == 'Chủ nhà';
        final isPrimary = index == 0;

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isPrimary ? const Color(0xFF10B981) : AppTheme.borderWarm,
              width: isPrimary ? 1.5 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: isOwner ? const Color(0xFFDCE8F3) : const Color(0xFFFFECE8),
                  child: Text(
                    c.name.isNotEmpty ? c.name[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isOwner ? const Color(0xFF26384F) : AppTheme.coralPink,
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            c.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isOwner ? const Color(0xFFE0F2FE) : const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              c.relationship,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOwner ? const Color(0xFF0284C7) : const Color(0xFFD97706),
                              ),
                            ),
                          ),
                          if (isPrimary)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '⭐ Ưu tiên gọi #1',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF059669),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '📞 ${c.phone}',
                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),

                IconButton(
                  icon: const Icon(Icons.phone_in_talk, color: Color(0xFF10B981)),
                  tooltip: 'Gọi thử ngay cho ${c.name}',
                  onPressed: () => _testEmergencyAlert(c),
                ),

                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: AppTheme.textSecondary, size: 20),
                  onSelected: (val) {
                    if (val == 'primary') _setPrimaryContact(c);
                    if (val == 'call') _testEmergencyAlert(c);
                    if (val == 'delete') _deleteContact(c);
                  },
                  itemBuilder: (ctx) => [
                    if (!isPrimary)
                      const PopupMenuItem(
                        value: 'primary',
                        child: Row(
                          children: [
                            Icon(Icons.star_rounded, color: Color(0xFFF59E0B), size: 18),
                            SizedBox(width: 8),
                            Text('Đặt làm số gọi ưu tiên #1'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'call',
                      child: Row(
                        children: [
                          Icon(Icons.call, color: Color(0xFF10B981), size: 18),
                          SizedBox(width: 8),
                          Text('Gọi thử ngay'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, color: AppTheme.coralPink, size: 18),
                          SizedBox(width: 8),
                          Text('Xóa liên hệ', style: TextStyle(color: AppTheme.coralPink)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }


  // ═══════════════════════════ TAB CHIA SẺ CAMERA ═══════════════════════════

  Widget _buildSharedMembersTab() {
    final owners = _sharedWithMe?.owners ?? const <SharedOwnerGroup>[];
    return RefreshIndicator(
      onRefresh: _loadSharedMembers,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        children: [
          _buildQrActionCard(),
          const SizedBox(height: 16),

          // ── Yêu cầu liên kết chờ duyệt (Owner) ──
          _sectionHeader(
            icon: Icons.mark_email_unread_outlined,
            title: 'Yêu cầu liên kết chờ duyệt',
            count: _incomingRequests.length,
          ),
          if (_requestsUnsupported != null)
            _infoBanner(
              icon: Icons.cloud_off_outlined,
              color: AppTheme.statusWarning,
              bg: AppTheme.statusWarningBg,
              text: _requestsUnsupported!,
            )
          else if (_incomingRequests.isEmpty)
            _emptyLine('Chưa có yêu cầu nào.')
          else
            ..._incomingRequests.map(_buildRequestCard),
          const SizedBox(height: 18),

          // ── Thành viên của tôi (tôi là Owner) ──
          _sectionHeader(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Thành viên của tôi',
            badge: 'Bạn là Owner',
            count: _sharedMembers.length,
          ),
          if (_membersError != null)
            _infoBanner(icon: Icons.error_outline, color: AppTheme.statusAlarm, bg: AppTheme.statusAlarmBg, text: _membersError!)
          else if (_isLoading && _sharedMembers.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else if (_sharedMembers.isEmpty)
            _emptyLine('Chưa cấp quyền cho ai. Quét mã QR của người thân để thêm thành viên.')
          else
            ..._sharedMembers.map(_buildOwnerMemberCard),
          const SizedBox(height: 18),

          // ── Được chia sẻ với tôi (tôi là Member) ──
          _sectionHeader(
            icon: Icons.family_restroom_outlined,
            title: 'Đang chia sẻ cho tôi',
            badge: 'Bạn là Member',
            count: owners.length,
          ),
          if (_sharedWithMeError != null)
            _infoBanner(icon: Icons.error_outline, color: AppTheme.statusAlarm, bg: AppTheme.statusAlarmBg, text: _sharedWithMeError!)
          else if (owners.isEmpty)
            _emptyLine('Chưa có Owner nào chia sẻ camera cho bạn.')
          else ...[
            if (_sharedWithMe?.derivedFromDevices == true)
              _infoBanner(
                icon: Icons.info_outline,
                color: AppTheme.securityBlue,
                bg: AppTheme.lightBlue,
                text: 'Backend chưa có API "được chia sẻ với tôi" (GET /api/members/shared-with-me) nên chưa hiện được '
                    'Gmail Owner và quyền chi tiết. Danh sách dưới đây lấy từ các thiết bị thật được chia sẻ.',
              ),
            ...owners.map(_buildSharedOwnerCard),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildQrActionCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF5B44BA), Color(0xFF7C3AED)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: AppTheme.royalPurple.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 26),
              SizedBox(width: 8),
              Text('Liên kết bằng mã QR',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Không cần gõ Gmail. Hai máy quét QR của nhau để liên kết camera.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _qrButton(
                  icon: Icons.qr_code_rounded,
                  label: 'Mã QR của tôi',
                  filled: true,
                  onTap: () => showMyQrSheet(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _qrButton(
                  icon: Icons.qr_code_scanner_rounded,
                  label: 'Quét mã QR',
                  filled: false,
                  onTap: _scanQr,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: _showShareAccountDialog,
              icon: const Icon(Icons.keyboard_alt_outlined, size: 16),
              label: const Text('Nhập Gmail thủ công', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qrButton({required IconData icon, required String label, required bool filled, required VoidCallback onTap}) {
    return Material(
      color: filled ? Colors.white : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: filled ? null : Border.all(color: Colors.white.withValues(alpha: 0.6)),
          ),
          child: Column(
            children: [
              Icon(icon, color: filled ? AppTheme.deepPurple : Colors.white, size: 26),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                    color: filled ? AppTheme.deepPurple : Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader({required IconData icon, required String title, String? badge, int? count}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.primaryNavy),
          const SizedBox(width: 6),
          Flexible(
            child: Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: AppTheme.softGray, borderRadius: BorderRadius.circular(10)),
              child: Text('$count', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.textSecondary)),
            ),
          ],
          const Spacer(),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFEDE9FE), borderRadius: BorderRadius.circular(10)),
              child: Text(badge, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppTheme.royalPurple)),
            ),
        ],
      ),
    );
  }

  Widget _infoBanner({required IconData icon, required Color color, required Color bg, required String text}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _emptyLine(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderWarm),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
    );
  }

  Widget _permChip(IconData icon, String text, {bool on = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: on ? AppTheme.statusArmedBg : AppTheme.softGray,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: on ? AppTheme.statusArmed : AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: on ? AppTheme.statusArmed : AppTheme.textSecondary,
                decoration: on ? null : TextDecoration.lineThrough,
              )),
        ],
      ),
    );
  }

  Widget _avatar(String seed, {Color bg = const Color(0xFFEDE9FE), Color fg = AppTheme.royalPurple}) {
    return CircleAvatar(
      radius: 22,
      backgroundColor: bg,
      child: Text(
        seed.isNotEmpty ? seed[0].toUpperCase() : '?',
        style: TextStyle(fontWeight: FontWeight.w800, color: fg, fontSize: 17),
      ),
    );
  }

  BoxDecoration get _cardDeco => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderWarm),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2))],
      );

  Widget _buildRequestCard(MemberLinkRequest r) {
    final name = r.requesterUsername.isNotEmpty ? r.requesterUsername : r.requesterEmail.split('@').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: _cardDeco.copyWith(border: Border.all(color: AppTheme.statusWarning, width: 1.2)),
      child: Column(
        children: [
          Row(
            children: [
              _avatar(name, bg: AppTheme.statusWarningBg, fg: const Color(0xFFB45309)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                    Text(r.requesterEmail, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                    const Text('muốn liên kết để xem camera của bạn',
                        style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.statusAlarm,
                    side: const BorderSide(color: AppTheme.statusAlarm),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _respondRequest(r, false),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Từ chối'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.statusArmed,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => _respondRequest(r, true),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Chấp nhận'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOwnerMemberCard(MemberModel m) {
    final name = m.memberUsername.isNotEmpty ? m.memberUsername : m.memberEmail.split('@').first;
    final scope = (m.deviceId == null || m.deviceId!.isEmpty) ? 'Tất cả thiết bị' : (m.deviceName ?? 'Một thiết bị');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: _cardDeco,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: AppTheme.lightBlue, borderRadius: BorderRadius.circular(8)),
                      child: const Text('Member',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.securityBlue)),
                    ),
                  ],
                ),
                Text(m.memberEmail, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _permChip(Icons.videocam_outlined, scope),
                    _permChip(Icons.notifications_none_rounded, 'Nhận cảnh báo'),
                    _permChip(Icons.notifications_off_outlined, 'Tắt chuông', on: m.canAcknowledge),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppTheme.textSecondary),
            onSelected: (v) {
              if (v == 'edit') _editMemberPermission(m);
              if (v == 'delete') _confirmRevoke(m);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'edit',
                child: Row(children: [
                  Icon(Icons.tune_rounded, size: 18, color: AppTheme.primaryNavy),
                  SizedBox(width: 8),
                  Text('Chỉnh sửa quyền'),
                ]),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(children: [
                  Icon(Icons.person_remove_outlined, size: 18, color: AppTheme.coralPink),
                  SizedBox(width: 8),
                  Text('Xóa thành viên', style: TextStyle(color: AppTheme.coralPink)),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSharedOwnerCard(SharedOwnerGroup g) {
    final hasEmail = g.ownerEmail.isNotEmpty;
    final shortId = g.ownerId.length > 8 ? g.ownerId.substring(0, 8) : g.ownerId;
    final title = g.ownerUsername.isNotEmpty
        ? g.ownerUsername
        : (hasEmail ? g.ownerEmail.split('@').first : 'Owner #$shortId');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: _cardDeco,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(title, bg: const Color(0xFFDCE8F3), fg: AppTheme.primaryNavy),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: const Color(0xFFFFECE5), borderRadius: BorderRadius.circular(8)),
                      child: const Text('Owner',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.coralPink)),
                    ),
                  ],
                ),
                Text(hasEmail ? g.ownerEmail : 'Gmail chưa được backend cung cấp',
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (g.devices.isNotEmpty)
                      ...g.devices.map((d) => _permChip(Icons.videocam_outlined, d.name))
                    else
                      _permChip(Icons.videocam_outlined, 'Camera được chia sẻ'),
                    _permChip(Icons.notifications_none_rounded, 'Nhận cảnh báo'),
                    if (g.canAcknowledge != null)
                      _permChip(Icons.notifications_off_outlined, 'Tắt chuông', on: g.canAcknowledge!),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: AppTheme.textSecondary),
                    SizedBox(width: 4),
                    Expanded(
                      child: Text('Quyền do Owner cấp, bạn không thể tự chỉnh sửa.',
                          style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════ HÀNH ĐỘNG ═══════════════════════════

  void _toast(String text, {Color color = AppTheme.statusArmed}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  Future<void> _scanQr() async {
    final payload = await Navigator.of(context).push<MemberQrPayload>(
      MaterialPageRoute(builder: (_) => const MemberQrScanScreen()),
    );
    if (payload == null || !mounted) return;

    if (payload.email == MemberService.myEmail.toLowerCase()) {
      _toast('Đây là mã QR của chính bạn. Hãy quét mã QR trên máy của người kia.', color: AppTheme.statusWarning);
      return;
    }
    await _showScannedSheet(payload);
  }

  Future<void> _showScannedSheet(MemberQrPayload p) async {
    final alreadyMember = _sharedMembers.any((m) => m.memberEmail.toLowerCase() == p.email);
    final displayName = p.name.isNotEmpty ? p.name : p.email.split('@').first;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.creamBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + MediaQuery.of(ctx).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _avatar(displayName),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                      Text(p.email, style: const TextStyle(color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                const Icon(Icons.verified_rounded, color: AppTheme.statusArmed),
              ],
            ),
            const SizedBox(height: 6),
            const Text('Đã đọc Gmail từ mã QR. Bạn muốn làm gì?',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.deepPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () => Navigator.pop(ctx, 'request'),
              icon: const Icon(Icons.send_rounded),
              label: const Text('Gửi yêu cầu liên kết tới Owner này',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.coralPink,
                side: const BorderSide(color: AppTheme.coralPink),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: alreadyMember ? null : () => Navigator.pop(ctx, 'grant'),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(alreadyMember ? 'Đã là thành viên của bạn' : 'Tôi là Owner – thêm người này làm Member'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;
    if (action == 'request') await _sendLinkRequest(p);
    if (action == 'grant') await _grantAccess(p.email);
  }

  Future<void> _sendLinkRequest(MemberQrPayload p) async {
    try {
      await MemberService.sendLinkRequest(p.email);
      _toast('Đã gửi yêu cầu liên kết tới ${p.email}. Chờ Owner chấp nhận.');
      await _loadSharedMembers();
    } on MemberFeatureUnsupported catch (e) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(children: [
            Icon(Icons.cloud_off_outlined, color: AppTheme.statusWarning),
            SizedBox(width: 8),
            Expanded(child: Text('Chưa gửi được yêu cầu', style: TextStyle(fontSize: 16))),
          ]),
          content: Text(
            '$e\n\nCách dùng được ngay với backend hiện tại: mở "Mã QR của tôi" trên máy bạn '
            'để Owner (${p.email}) quét và thêm bạn làm Member.',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.deepPurple, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(ctx);
                showMyQrSheet(context);
              },
              child: const Text('Mở QR của tôi'),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('$e', color: AppTheme.statusAlarm);
    }
  }

  Future<void> _grantAccess(String email) async {
    final choice = await showPermissionSheet(
      context,
      title: 'Cấp quyền cho Member',
      memberEmail: email,
      devices: _myDevices,
      confirmLabel: 'Thêm thành viên',
    );
    if (choice == null) return;
    try {
      final msg = await MemberService.shareTo(email, deviceId: choice.deviceId, canAcknowledge: choice.canAcknowledge);
      await _loadSharedMembers();
      _toast(msg);
    } catch (e) {
      _toast('$e', color: AppTheme.statusAlarm);
    }
  }

  Future<void> _respondRequest(MemberLinkRequest r, bool accept) async {
    PermissionChoice? choice;
    if (accept) {
      choice = await showPermissionSheet(
        context,
        title: 'Chấp nhận & cấp quyền',
        memberEmail: r.requesterEmail,
        devices: _myDevices,
        confirmLabel: 'Chấp nhận',
      );
      if (choice == null) return;
    }
    try {
      await MemberService.respondRequest(
        r.id,
        accept: accept,
        deviceId: choice?.deviceId,
        canAcknowledge: choice?.canAcknowledge ?? true,
      );
      await _loadSharedMembers();
      _toast(accept ? 'Đã chấp nhận ${r.requesterEmail}' : 'Đã từ chối yêu cầu của ${r.requesterEmail}');
    } catch (e) {
      _toast('$e', color: AppTheme.statusAlarm);
    }
  }

  Future<void> _editMemberPermission(MemberModel m) async {
    final choice = await showPermissionSheet(
      context,
      title: 'Chỉnh sửa quyền',
      memberEmail: m.memberEmail,
      devices: _myDevices,
      initialDeviceId: m.deviceId,
      initialCanAck: m.canAcknowledge,
    );
    if (choice == null) return;
    if ((choice.deviceId ?? '') == (m.deviceId ?? '') && choice.canAcknowledge == m.canAcknowledge) return;
    try {
      await MemberService.updatePermission(m, deviceId: choice.deviceId, canAcknowledge: choice.canAcknowledge);
      await _loadSharedMembers();
      _toast('Đã cập nhật quyền của ${m.memberEmail}');
    } catch (e) {
      await _loadSharedMembers();
      _toast('Không cập nhật được quyền: $e', color: AppTheme.statusAlarm);
    }
  }

  Future<void> _confirmRevoke(MemberModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Xóa thành viên?'),
        content: Text('${m.memberEmail} sẽ không còn xem camera và nhận cảnh báo của bạn nữa.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.coralPink, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok == true) await _revokeSharedMember(m);
  }

  Future<void> _showShareAccountDialog() async {
    final emailCtrl = TextEditingController();
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Thêm Member bằng Gmail', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Nhập Gmail tài khoản SmartGuard của người thân (không cần mật khẩu, không gửi email).',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Gmail người thân *',
                prefixIcon: Icon(Icons.email_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.coralPink, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, emailCtrl.text.trim()),
            child: const Text('Tiếp tục'),
          ),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    await _grantAccess(email);
  }

  Future<void> _revokeSharedMember(MemberModel m) async {
    try {
      await MemberService.revoke(m.id);
      await _loadSharedMembers();
      _toast('Đã xóa ${m.memberEmail} khỏi thành viên');
    } catch (e) {
      _toast('$e', color: AppTheme.statusAlarm);
    }
  }
}
