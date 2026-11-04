import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api_client.dart';
import '../../core/app_config.dart';
import '../../core/app_theme.dart';
import '../../models/models.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = true;
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _systemInfo;
  List<UserModel> _users = [];
  List<DeviceModel> _devices = [];
  List<ImageItemModel> _images = [];
  List<KnownPersonModel> _knownPersons = [];
  String _userSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadAdminData();
    _loadKnownPersons();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAdminData() async {
    setState(() => _isLoading = true);
    try {
      final statsRes = await ApiClient.request('GET', '/api/admin/stats');
      final systemRes = await ApiClient.request('GET', '/api/admin/system');
      final usersRes =
          await ApiClient.request('GET', '/api/admin/users') as List<dynamic>;

      List<ImageItemModel> imgList = [];
      try {
        final imgRes =
            await ApiClient.request('GET', '/api/images/list?limit=60')
                as List<dynamic>;
        imgList = imgRes
            .map((e) => ImageItemModel.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}

      List<DeviceModel> devList = [];
      try {
        final devRes = await ApiClient.request('GET', '/api/devices') as List<dynamic>;
        devList = devRes.map((e) => DeviceModel.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _stats = statsRes as Map<String, dynamic>?;
          _systemInfo = systemRes as Map<String, dynamic>?;
          _users = usersRes
              .map((e) => UserModel.fromJson(e as Map<String, dynamic>))
              .toList();
          _images = imgList;
          _devices = devList;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Quản lý người quen đã đăng ký (lưu trong SharedPreferences để CameraGuardScreen tự động tắt cảnh báo khi phát hiện)
  Future<void> _loadKnownPersons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('sg_known_persons');
      if (str != null && str.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(str);
        if (mounted) {
          setState(() {
            _knownPersons = jsonList
                .map(
                  (e) => KnownPersonModel.fromJson(e as Map<String, dynamic>),
                )
                .toList();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveKnownPersons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _knownPersons.map((e) => e.toJson()).toList();
      await prefs.setString('sg_known_persons', jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> _addKnownPerson({required String name, String? photoUrl}) async {
    final newPerson = KnownPersonModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      photoUrl: photoUrl,
      registeredAt: DateTime.now(),
    );
    setState(() {
      _knownPersons.insert(0, newPerson);
    });
    await _saveKnownPersons();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã đăng ký người quen "$name". Camera sẽ tự động tắt cảnh báo khi nhận diện!',
          ),
          backgroundColor: AppTheme.statusArmed,
        ),
      );
    }
  }

  Future<void> _deleteKnownPerson(String id) async {
    setState(() {
      _knownPersons.removeWhere((p) => p.id == id);
    });
    await _saveKnownPersons();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã xóa người quen khỏi danh sách nhận diện.'),
        ),
      );
    }
  }

  // Khóa / Mở khóa tài khoản
  Future<void> _toggleUserLock(UserModel user) async {
    try {
      await ApiClient.request(
        'PATCH',
        '/api/admin/users/${user.id}/status',
        body: {'isLocked': !user.isLocked},
      );
      _loadAdminData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              user.isLocked
                  ? 'Đã mở khóa tài khoản ${user.username}'
                  : 'Đã khóa tài khoản ${user.username}',
            ),
            backgroundColor: user.isLocked
                ? AppTheme.statusArmed
                : AppTheme.statusAlarm,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi: $e'),
            backgroundColor: AppTheme.statusAlarm,
          ),
        );
      }
    }
  }

  // Đổi nhanh vai trò Admin <-> User cho tài khoản đã tồn tại (không cần mật khẩu)
  Future<void> _quickToggleUserRole(UserModel user) async {
    final isCurrentlyAdmin = user.role.toLowerCase() == 'admin';
    final nextRole = isCurrentlyAdmin ? 'Owner' : 'Admin';
    try {
      await ApiClient.request(
        'PUT',
        '/api/admin/users/${user.id}',
        body: {
          'username': user.username,
          'email': user.email,
          'role': nextRole,
          'isLocked': user.isLocked,
        },
      );
      _loadAdminData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Đã đổi quyền tài khoản ${user.username} thành ${nextRole == 'Admin' ? 'Quản trị (Admin)' : 'Người dùng (User)'} (không cần nhập mật khẩu)!',
            ),
            backgroundColor: AppTheme.statusArmed,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi: $e'),
            backgroundColor: AppTheme.statusAlarm,
          ),
        );
      }
    }
  }

  // Thêm tài khoản mới (Admin hoặc User)
  Future<void> _showAddUserDialog() async {
    final formKey = GlobalKey<FormState>();
    final usernameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String selectedRole = 'Owner'; // 'Owner' = User, 'Admin' = Admin

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.person_add, color: AppTheme.primaryBlue),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Thêm tài khoản mới',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '💡 Mẹo: Biểu mẫu này dùng để TẠO MỚI một tài khoản chưa từng đăng ký (cần tạo mật khẩu ban đầu). Nếu chỉ muốn đổi quyền Admin/User cho tài khoản đã có, hãy chạm trực tiếp vào nhãn Admin/User trên danh sách bên ngoài!',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ),
                  TextFormField(
                    controller: usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tên người dùng (Username) *',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'Tối thiểu 3 ký tự'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Địa chỉ Email *',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Email không hợp lệ'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passwordCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu *',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'Tối thiểu 6 ký tự'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Phân quyền tài khoản:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(Icons.person_outline, size: 16),
                          label: const Text('Người dùng', style: TextStyle(fontSize: 12)),
                          selected: selectedRole == 'Owner',
                          selectedColor: AppTheme.primaryBlue.withValues(
                            alpha: 0.2,
                          ),
                          onSelected: (val) {
                            if (val)
                              setDialogState(() => selectedRole = 'Owner');
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(
                            Icons.admin_panel_settings_outlined,
                            size: 16,
                          ),
                          label: const Text('Quản trị', style: TextStyle(fontSize: 12)),
                          selected: selectedRole == 'Admin',
                          selectedColor: const Color(
                            0xFF7C3AED,
                          ).withValues(alpha: 0.2),
                          onSelected: (val) {
                            if (val)
                              setDialogState(() => selectedRole = 'Admin');
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                try {
                  try {
                    await ApiClient.request(
                      'POST',
                      '/api/admin/users',
                      body: {
                        'username': usernameCtrl.text.trim(),
                        'email': emailCtrl.text.trim(),
                        'password': passwordCtrl.text,
                        'role': selectedRole,
                      },
                    );
                  } catch (adminErr) {
                    // Nếu chưa có quyền Admin (401/403) hoặc chưa đăng nhập, sử dụng API đăng ký công khai
                    await ApiClient.request(
                      'POST',
                      '/api/auth/register',
                      body: {
                        'username': usernameCtrl.text.trim(),
                        'email': emailCtrl.text.trim(),
                        'password': passwordCtrl.text,
                        'role': selectedRole,
                      },
                    );
                  }
                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Đã tạo tài khoản $selectedRole thành công!',
                        ),
                        backgroundColor: AppTheme.statusArmed,
                      ),
                    );
                    _loadAdminData();
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Lỗi: $e'),
                      backgroundColor: AppTheme.statusAlarm,
                    ),
                  );
                }
              },
              child: const Text('Tạo tài khoản'),
            ),
          ],
        ),
      ),
    );
  }

  // Chỉnh sửa tài khoản (Sửa thông tin, đổi vai trò, đổi mật khẩu)
  Future<void> _showEditUserDialog(UserModel user) async {
    final formKey = GlobalKey<FormState>();
    final usernameCtrl = TextEditingController(text: user.username);
    final emailCtrl = TextEditingController(text: user.email);
    final passwordCtrl = TextEditingController();
    String selectedRole = user.role.toLowerCase() == 'admin'
        ? 'Admin'
        : 'Owner';
    bool isLocked = user.isLocked;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.edit, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sửa: ${user.username}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '💡 Mẹo: Biểu mẫu này dùng để TẠO MỚI một tài khoản chưa từng đăng ký (cần tạo mật khẩu ban đầu). Nếu chỉ muốn đổi quyền Admin/User cho tài khoản đã có, hãy chạm trực tiếp vào nhãn Admin/User trên danh sách bên ngoài!',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ),
                  TextFormField(
                    controller: usernameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tên người dùng (Username) *',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v == null || v.trim().length < 3)
                        ? 'Tối thiểu 3 ký tự'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Địa chỉ Email *',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Email không hợp lệ'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passwordCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu mới (để trống nếu không đổi)',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                    validator: (v) {
                      if (v != null && v.isNotEmpty && v.length < 6) {
                        return 'Tối thiểu 6 ký tự';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Phân quyền tài khoản:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(Icons.person, size: 16),
                          label: const Text('Người dùng (User)'),
                          selected: selectedRole == 'Owner',
                          selectedColor: AppTheme.primaryBlue.withValues(
                            alpha: 0.2,
                          ),
                          onSelected: (val) {
                            if (val)
                              setDialogState(() => selectedRole = 'Owner');
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(
                            Icons.admin_panel_settings,
                            size: 16,
                          ),
                          label: const Text('Quản trị (Admin)'),
                          selected: selectedRole == 'Admin',
                          selectedColor: const Color(
                            0xFF7C3AED,
                          ).withValues(alpha: 0.2),
                          onSelected: (val) {
                            if (val)
                              setDialogState(() => selectedRole = 'Admin');
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('Khóa tài khoản này'),
                    value: isLocked,
                    activeThumbColor: AppTheme.statusAlarm,
                    onChanged: (val) => setDialogState(() => isLocked = val),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                try {
                  final Map<String, dynamic> body = {
                    'username': usernameCtrl.text.trim(),
                    'email': emailCtrl.text.trim(),
                    'role': selectedRole,
                    'isLocked': isLocked,
                  };
                  if (passwordCtrl.text.trim().isNotEmpty) {
                    body['password'] = passwordCtrl.text;
                  }

                  await ApiClient.request(
                    'PUT',
                    '/api/admin/users/${user.id}',
                    body: body,
                  );
                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Đã cập nhật thông tin tài khoản thành công!',
                        ),
                        backgroundColor: AppTheme.statusArmed,
                      ),
                    );
                    _loadAdminData();
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Lỗi: $e'),
                      backgroundColor: AppTheme.statusAlarm,
                    ),
                  );
                }
              },
              child: const Text('Lưu thay đổi'),
            ),
          ],
        ),
      ),
    );
  }

  // Xóa tài khoản
  Future<void> _deleteUser(UserModel user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa tài khoản'),
        content: Text(
          'Bạn có chắc chắn muốn xóa tài khoản "${user.username}" (${user.email}) khỏi hệ thống?\nHành động này không thể hoàn tác.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusAlarm,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa tài khoản'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await ApiClient.request('DELETE', '/api/admin/users/${user.id}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Đã xóa tài khoản "${user.username}" thành công.'),
              backgroundColor: AppTheme.statusArmed,
            ),
          );
          _loadAdminData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Lỗi xóa: $e'),
              backgroundColor: AppTheme.statusAlarm,
            ),
          );
        }
      }
    }
  }

  // Xóa ảnh
  Future<void> _deleteImage(ImageItemModel img) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa hình ảnh'),
        content: const Text(
          'Bạn có chắc chắn muốn xóa hình ảnh này khỏi hệ thống?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.statusAlarm,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa ảnh'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await ApiClient.request('DELETE', '/api/images/${img.id}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Đã xóa ảnh thành công!'),
              backgroundColor: AppTheme.statusArmed,
            ),
          );
          _loadAdminData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Lỗi: $e'),
              backgroundColor: AppTheme.statusAlarm,
            ),
          );
        }
      }
    }
  }

  // Dialog đăng ký người quen mới
  Future<void> _showAddKnownPersonDialog({String? presetImageUrl}) async {
    final nameCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.face_retouching_natural, color: AppTheme.statusArmed),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Thêm Người Quen',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Đăng ký khuôn mặt người thân / người quen để hệ thống TỰ ĐỘNG TẮT CẢNH BÁO khi phát hiện trước camera.',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Họ và tên người quen *',
                prefixIcon: Icon(Icons.badge_outlined),
                hintText: 'Ví dụ: Bố, Mẹ, Bạn Thân...',
              ),
            ),
            if (presetImageUrl != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  '${AppConfig.baseUrl}$presetImageUrl',
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, size: 50),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              _addKnownPerson(name: name, photoUrl: presetImageUrl);
            },
            child: const Text('Xác nhận lưu'),
          ),
        ],
      ),
    );
  }

  // Xem ảnh lớn
  void _previewImage(String url) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Text(
                      'Không thể tải ảnh.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredUsers = _users.where((u) {
      if (_userSearchQuery.isEmpty) return true;
      final q = _userSearchQuery.toLowerCase();
      return u.username.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          u.role.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            Image.asset(
              'assets/images/3bc65821-0388-43aa-aba6-16fc6a3912a4.png',
              height: 32,
              errorBuilder: (_, __, ___) => const Icon(Icons.admin_panel_settings, color: Color(0xFF7C3AED)),
            ),
            const SizedBox(width: 8),
            const Text(
              'Quản trị hệ thống (Admin)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAdminData,
            tooltip: 'Làm mới',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF7C3AED),
          labelColor: const Color(0xFF7C3AED),
          unselectedLabelColor: AppTheme.textSecondary,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.manage_accounts), text: 'Tài khoản'),
            Tab(icon: Icon(Icons.devices_other), text: 'Thiết bị IoT'),
            Tab(icon: Icon(Icons.photo_library), text: 'Ảnh & Khuôn mặt'),
            Tab(icon: Icon(Icons.analytics_outlined), text: 'Hệ thống'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildUsersTab(filteredUsers),
                _buildDevicesTab(),
                _buildImagesAndKnownPersonsTab(),
                _buildSystemTab(),
              ],
            ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF7C3AED),
              foregroundColor: Colors.white,
              onPressed: _showAddUserDialog,
              icon: const Icon(Icons.person_add),
              label: const Text('Thêm tài khoản'),
            )
          : null,
    );
  }

  Widget _buildUsersTab(List<UserModel> usersList) {
    final adminCount = _users
        .where((u) => u.role.toLowerCase() == 'admin')
        .length;
    final userCount = _users.length - adminCount;
    final lockedCount = _users.where((u) => u.isLocked).length;

    return RefreshIndicator(
      onRefresh: _loadAdminData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Thống kê tài khoản nhanh
          Row(
            children: [
              Expanded(
                child: _buildMiniStat(
                  'Tổng',
                  '${_users.length}',
                  Icons.people,
                  AppTheme.primaryBlue,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniStat(
                  'Admin',
                  '$adminCount',
                  Icons.admin_panel_settings,
                  const Color(0xFF7C3AED),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniStat(
                  'User',
                  '$userCount',
                  Icons.person,
                  AppTheme.accentCyan,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniStat(
                  'Đã khóa',
                  '$lockedCount',
                  Icons.lock,
                  AppTheme.statusAlarm,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Tìm kiếm người dùng
          TextField(
            decoration: InputDecoration(
              hintText: 'Tìm kiếm theo tên, email hoặc vai trò...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _userSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _userSearchQuery = ''),
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (val) => setState(() => _userSearchQuery = val),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Danh sách tài khoản (${usersList.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: _showAddUserDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Thêm mới'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (usersList.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              child: const Text(
                'Không tìm thấy người dùng nào phù hợp.',
                style: TextStyle(color: Color(0xFF64748B)),
              ),
            )
          else
            ...usersList.map((user) {
              final isAdmin = user.role.toLowerCase() == 'admin';
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: user.isLocked
                        ? AppTheme.statusAlarm.withValues(alpha: 0.5)
                        : const Color(0xFFE2E8F0),
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  leading: CircleAvatar(
                    radius: 22,
                    backgroundColor: user.isLocked
                        ? AppTheme.statusAlarm
                        : (isAdmin
                              ? const Color(0xFF7C3AED)
                              : AppTheme.primaryBlue),
                    child: Text(
                      user.username.isNotEmpty
                          ? user.username[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.username,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _quickToggleUserRole(user),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: isAdmin
                                ? const Color(0xFF7C3AED).withValues(alpha: 0.15)
                                : AppTheme.primaryBlue.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isAdmin ? 'Admin' : 'User',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isAdmin
                                      ? const Color(0xFF7C3AED)
                                      : AppTheme.primaryBlue,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.swap_horiz,
                                size: 12,
                                color: isAdmin
                                    ? const Color(0xFF7C3AED)
                                    : AppTheme.primaryBlue,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (user.isLocked) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.statusAlarm.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Khóa',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.statusAlarm,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    user.email,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (value) {
                      if (value == 'role') {
                        _quickToggleUserRole(user);
                      } else if (value == 'edit') {
                        _showEditUserDialog(user);
                      } else if (value == 'lock') {
                        _toggleUserLock(user);
                      } else if (value == 'delete') {
                        _deleteUser(user);
                      }
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'role',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.swap_horiz,
                              size: 18,
                              color: Color(0xFF7C3AED),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isAdmin
                                  ? 'Đổi sang quyền User (không cần MK)'
                                  : 'Cấp quyền Admin (không cần MK)',
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(
                              Icons.edit,
                              size: 18,
                              color: AppTheme.primaryBlue,
                            ),
                            SizedBox(width: 8),
                            Text('Sửa tài khoản'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'lock',
                        child: Row(
                          children: [
                            Icon(
                              user.isLocked ? Icons.lock_open : Icons.lock,
                              size: 18,
                              color: Colors.orange,
                            ),
                            SizedBox(width: 8),
                            Text(
                              user.isLocked
                                  ? 'Mở khóa tài khoản'
                                  : 'Khóa tài khoản',
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_forever,
                              size: 18,
                              color: AppTheme.statusAlarm,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Xóa tài khoản',
                              style: TextStyle(color: AppTheme.statusAlarm),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildDevicesTab() {
    final cameraCount = _devices.where((d) => d.deviceType.toLowerCase() == 'camera').length;
    final sensorCount = _devices.where((d) => d.deviceType.toLowerCase() == 'sensor').length;
    final armedCount = _devices.where((d) => d.isArmed).length;

    return RefreshIndicator(
      onRefresh: _loadAdminData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: _buildMiniStat('Tổng thiết bị', '${_devices.length}', Icons.devices, AppTheme.coralPink)),
              const SizedBox(width: 8),
              Expanded(child: _buildMiniStat('Camera', '$cameraCount', Icons.videocam, AppTheme.royalPurple)),
              const SizedBox(width: 8),
              Expanded(child: _buildMiniStat('Cảm biến', '$sensorCount', Icons.sensors, const Color(0xFFF59E0B))),
              const SizedBox(width: 8),
              Expanded(child: _buildMiniStat('Đang bật', '$armedCount', Icons.shield, AppTheme.statusArmed)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Thiết bị IoT toàn hệ thống (${_devices.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textPrimary),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _loadAdminData,
                tooltip: 'Làm mới',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_devices.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              child: const Text('Chưa có thiết bị nào kết nối vào hệ thống.', style: TextStyle(color: Color(0xFF64748B))),
            )
          else
            ..._devices.map((dev) {
              final isArmed = dev.isArmed;
              final isSensor = dev.deviceType.toLowerCase() == 'sensor';
              final isDoorbell = dev.deviceType.toLowerCase() == 'doorbell';

              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppTheme.borderWarm),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFFFECE8),
                    child: Icon(
                      isSensor ? Icons.sensors : (isDoorbell ? Icons.doorbell : Icons.videocam),
                      color: AppTheme.coralPink,
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          dev.name,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isArmed ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isArmed ? 'Online' : 'Offline',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isArmed ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    'Vị trí: ${dev.location.isNotEmpty ? dev.location : "Cửa chính"} • ID: ${dev.id.substring(0, dev.id.length > 8 ? 8 : dev.id.length)}...',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (val) async {
                      if (val == 'toggle') {
                        try {
                          await ApiClient.request('PATCH', '/api/devices/${dev.id}/toggle-arm');
                          _loadAdminData();
                        } catch (_) {}
                      } else if (val == 'delete') {
                        try {
                          await ApiClient.request('DELETE', '/api/devices/${dev.id}');
                          _loadAdminData();
                        } catch (_) {}
                      }
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'toggle',
                        child: Row(
                          children: [
                            Icon(isArmed ? Icons.shield_outlined : Icons.shield, color: AppTheme.coralPink, size: 18),
                            const SizedBox(width: 8),
                            Text(isArmed ? 'Tắt bảo vệ' : 'Bật bảo vệ'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, color: AppTheme.coralPink, size: 18),
                            SizedBox(width: 8),
                            Text('Xóa khỏi hệ thống', style: TextStyle(color: AppTheme.coralPink)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildImagesAndKnownPersonsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // SECTION 1: Người quen đã đăng ký (Khuôn mặt bỏ qua cảnh báo)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.statusArmed.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppTheme.statusArmed.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.verified_user,
                    color: AppTheme.statusArmed,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Khuôn mặt Người quen (Tắt cảnh báo)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Khi camera quét thấy mặt người quen, hệ thống sẽ TỰ ĐỘNG TẮT còi báo động.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: AppTheme.statusArmed,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _showAddKnownPersonDialog(),
                    icon: const Icon(Icons.person_add, size: 20),
                    tooltip: 'Thêm người quen',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_knownPersons.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Chưa có người quen nào được đăng ký. Bấm nút [+] để thêm tên người thân.',
                    style: TextStyle(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF64748B),
                    ),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _knownPersons.map((person) {
                    return Chip(
                      avatar: CircleAvatar(
                        backgroundColor: AppTheme.statusArmed,
                        child: Text(
                          person.name.isNotEmpty
                              ? person.name[0].toUpperCase()
                              : 'N',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      label: Text(
                        person.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () => _deleteKnownPerson(person.id),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // SECTION 2: Danh sách hình ảnh trong máy & hệ thống
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Danh sách Hình ảnh hệ thống (${_images.length})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _loadAdminData,
              tooltip: 'Tải lại ảnh',
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (_images.isEmpty)
          Container(
            padding: const EdgeInsets.all(32),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Column(
              children: [
                Icon(
                  Icons.photo_library_outlined,
                  size: 48,
                  color: Color(0xFF94A3B8),
                ),
                SizedBox(height: 10),
                Text(
                  'Chưa có hình ảnh bằng chứng nào được lưu trong máy.',
                  style: TextStyle(color: Color(0xFF64748B)),
                ),
              ],
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.85,
            ),
            itemCount: _images.length,
            itemBuilder: (ctx, i) {
              final img = _images[i];
              final fullUrl = '${AppConfig.baseUrl}${img.relativeUrl}';

              return Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _previewImage(fullUrl),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.network(
                              fullUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: const Color(0xFFF1F5F9),
                                child: const Icon(
                                  Icons.broken_image,
                                  size: 36,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 6,
                              right: 6,
                              child: InkWell(
                                onTap: () => _deleteImage(img),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            img.fileName,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                            ),
                            icon: const Icon(Icons.face, size: 14),
                            label: const Text(
                              'Làm người quen',
                              style: TextStyle(fontSize: 10),
                            ),
                            onPressed: () => _showAddKnownPersonDialog(
                              presetImageUrl: img.relativeUrl,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildSystemTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_systemInfo != null) ...[
            Card(
              color: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.dns, color: AppTheme.accentCyan, size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Thông số Máy chủ Backend (.NET 9.0)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    const Divider(color: Color(0xFF334155), height: 24),
                    _buildInfoRow(
                      'Hệ điều hành',
                      '${_systemInfo!['osVersion']}',
                    ),
                    _buildInfoRow(
                      'Tên máy trạm',
                      '${_systemInfo!['machineName']}',
                    ),
                    _buildInfoRow(
                      '.NET Runtime',
                      '${_systemInfo!['dotnetVersion']}',
                    ),
                    _buildInfoRow(
                      'RAM đang dùng',
                      '${_systemInfo!['workingSetMemoryMb']} MB',
                    ),
                    _buildInfoRow(
                      'Số luồng Threads',
                      '${_systemInfo!['threads']}',
                    ),
                    _buildInfoRow(
                      'Thời gian chạy',
                      '${(_systemInfo!['uptimeSeconds'] as num?)?.toInt() ?? 0} giây',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (_stats != null) ...[
            const Text(
              'Thống kê An ninh Toàn cục',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildBigStat(
                    'Tổng Người dùng',
                    '${_stats!['totalUsers']}',
                    Icons.people,
                    AppTheme.primaryBlue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildBigStat(
                    'Tổng Thiết bị',
                    '${_stats!['totalDevices']}',
                    Icons.videocam,
                    AppTheme.accentCyan,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildBigStat(
                    'Cảnh báo hôm nay',
                    '${_stats!['totalAlertsToday']}',
                    Icons.warning_amber,
                    AppTheme.statusWarning,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildBigStat(
                    'Đang Canh gác',
                    '${_stats!['activeArmedDevices']}',
                    Icons.shield,
                    AppTheme.statusArmed,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMiniStat(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  Widget _buildBigStat(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String title, String val) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
          Text(
            val,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
