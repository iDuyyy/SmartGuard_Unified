import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/session_manager.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import 'otp_screen.dart';
import 'register_screen.dart';
import '../home_shell.dart';
import '../admin/admin_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _rememberMe = true;
  bool _deviceSupportsBiometric = false;
  UserModel? _savedBioUser;

  bool _bioBusy = false;
  bool _autoPromptDone = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkBiometric() async {
    final canBio = await AuthService.canUseBiometric();
    final enabled = await SessionManager.isBiometricEnabled();
    final savedUser = enabled ? await SessionManager.getSavedBiometricUser() : null;
    if (!mounted) return;

    setState(() {
      _deviceSupportsBiometric = canBio;
      _savedBioUser = savedUser;
      if (savedUser != null && _identifierController.text.isEmpty) {
        _identifierController.text = savedUser.email.isNotEmpty ? savedUser.email : savedUser.username;
      }
    });

    // Tự mở hộp thoại vân tay đúng 1 lần khi vào màn hình (nếu đã liên kết)
    if (canBio && savedUser != null && !SessionManager.isLoggedIn && !_autoPromptDone) {
      _autoPromptDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _triggerBiometricLogin(silentCancel: true);
      });
    }
  }

  void _showBioMessage(String text, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }

  Future<void> _triggerBiometricLogin({bool silentCancel = false}) async {
    if (_bioBusy) return;
    setState(() => _bioBusy = true);
    try {
      final savedUser = await SessionManager.getSavedBiometricUser();
      if (savedUser == null || !await SessionManager.isBiometricEnabled()) {
        _showBioMessage(
          'Chưa có tài khoản nào bật đăng nhập vân tay trên máy này. Hãy đăng nhập bằng mật khẩu, '
          'sau đó bật "Đăng nhập bằng Vân tay" trong Cài đặt.',
          AppTheme.statusWarning,
        );
        return;
      }

      final displayName = savedUser.username.isNotEmpty
          ? savedUser.username
          : (savedUser.email.isNotEmpty ? savedUser.email : 'tài khoản đã liên kết');

      final auth = await AuthService.authenticateBiometric(
        reason: 'Quét vân tay để đăng nhập vào tài khoản $displayName',
      );
      if (auth.busy) return;
      if (!auth.success) {
        final cancelled = (auth.message ?? '').contains('hủy');
        if (!(silentCancel && cancelled)) {
          _showBioMessage(auth.message ?? 'Xác thực vân tay thất bại.', AppTheme.statusWarning);
        }
        return;
      }

      final result = await SessionManager.restoreBiometricSession();
      if (!mounted) return;

      switch (result.status) {
        case BiometricRestoreStatus.success:
          break;
        case BiometricRestoreStatus.notLinked:
          _showBioMessage('Chưa có tài khoản liên kết vân tay. Vui lòng đăng nhập bằng mật khẩu.', AppTheme.statusAlarm);
          return;
        case BiometricRestoreStatus.tokenMissing:
        case BiometricRestoreStatus.tokenExpired:
          _showBioMessage(
            'Phiên vân tay của $displayName đã hết hạn. Vui lòng đăng nhập mật khẩu 1 lần để làm mới, '
            'vân tay sẽ tiếp tục dùng được.',
            AppTheme.statusWarning,
          );
          return;
        case BiometricRestoreStatus.accountMismatch:
          _showBioMessage('Dữ liệu vân tay không khớp tài khoản $displayName. Vui lòng đăng nhập bằng mật khẩu.', AppTheme.statusAlarm);
          return;
      }

      final user = result.user ?? savedUser;
      final name = user.username.isNotEmpty ? user.username : (user.email.isNotEmpty ? user.email : displayName);
      _showBioMessage('Xin chào $name! Đăng nhập vân tay thành công.', AppTheme.statusArmed);

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } finally {
      if (mounted) setState(() => _bioBusy = false);
    }
  }

  Future<void> _submitLogin() async {
    final identifier = _identifierController.text.trim();
    final password = _passwordController.text;

    if (identifier.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập tài khoản và mật khẩu.')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final res = await AuthService.login(identifier: identifier, password: password);
      final challengeId = res['challengeId']?.toString() ?? '';
      final maskedEmail = res['email']?.toString() ?? identifier;
      final devOtp = res['devOtp']?.toString();

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpScreen(
            challengeId: challengeId,
            maskedEmail: maskedEmail,
            devOtp: devOtp,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppTheme.statusAlarm,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showForgotPasswordDialog() {
    final emailCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardWhite,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Image.asset('assets/images/lock.png', width: 36, height: 36),
            const SizedBox(width: 10),
            const Text('Quên mật khẩu', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Nhập email của bạn, chúng tôi sẽ gửi hướng dẫn đặt lại mật khẩu an toàn.',
              style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Nhập email',
                prefixIcon: Icon(Icons.email_outlined, color: AppTheme.coralPink),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy', style: TextStyle(color: AppTheme.secondaryText))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.deepPurple),
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Đã gửi mã khôi phục về email của bạn!'),
                  backgroundColor: AppTheme.statusArmed,
                ),
              );
            },
            child: const Text('Gửi hướng dẫn'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bioName = _savedBioUser != null
        ? (_savedBioUser!.username.isNotEmpty
            ? _savedBioUser!.username
            : (_savedBioUser!.email.isNotEmpty ? _savedBioUser!.email : null))
        : null;

    final bioLabel = bioName != null && bioName.isNotEmpty
        ? 'Đăng nhập vân tay ($bioName)'
        : 'Đăng nhập bằng Vân tay';

    return Scaffold(
      backgroundColor: AppTheme.creamBg,
      appBar: AppBar(
        title: const Text('🐾 ĐĂNG NHẬP & XÁC THỰC', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.secondaryText)),
        actions: [
          IconButton(
            icon: const Icon(Icons.admin_panel_settings_outlined, color: AppTheme.primaryNavy),
            tooltip: 'Quản trị hệ thống (Admin)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),

              // Cute Header
              const Text(
                'Chào mừng trở lại! 👋',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.headingDark,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Đăng nhập để tiếp tục bảo vệ ngôi nhà của bạn',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
              ),
              const SizedBox(height: 20),

              Center(
                child: Container(
                  width: 110,
                  height: 110,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF2E6),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.borderWarm, width: 2),
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/sticker_login_screen.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.pets,
                        color: AppTheme.coralPink,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 26),

              // Email / Username Field
              TextField(
                controller: _identifierController,
                decoration: const InputDecoration(
                  labelText: 'Email hoặc Tên đăng nhập',
                  hintText: 'example@gmail.com',
                  prefixIcon: Icon(Icons.mail_outline_rounded, color: AppTheme.coralPink),
                ),
              ),
              const SizedBox(height: 14),

              // Password Field
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.coralPink),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: AppTheme.secondaryText),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Remember Me & Forgot Password
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: _rememberMe,
                          activeColor: AppTheme.primaryNavy,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                          onChanged: (v) => setState(() => _rememberMe = v ?? true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('Ghi nhớ đăng nhập', style: TextStyle(fontSize: 13, color: AppTheme.headingDark, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  GestureDetector(
                    onTap: _showForgotPasswordDialog,
                    child: const Text(
                      'Quên mật khẩu?',
                      style: TextStyle(fontSize: 13, color: AppTheme.royalPurple, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),

              // Gradient Button: Đăng nhập
              Container(
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.coralPink.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submitLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Đăng nhập',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Social or Biometric
              const Center(
                child: Text('hoặc', style: TextStyle(color: AppTheme.secondaryText, fontSize: 13)),
              ),
              const SizedBox(height: 12),

              OutlinedButton.icon(
                onPressed: (_deviceSupportsBiometric && !_bioBusy) ? () => _triggerBiometricLogin() : null,
                icon: _bioBusy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fingerprint, color: AppTheme.primaryNavy, size: 24),
                label: Text(
                  bioLabel,
                  style: const TextStyle(color: AppTheme.primaryNavy, fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppTheme.cardWhite,
                  side: const BorderSide(color: AppTheme.borderWarm),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 24),

              // Register Link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Chưa có tài khoản? ', style: TextStyle(color: AppTheme.secondaryText)),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const RegisterScreen()),
                      );
                    },
                    child: const Text(
                      'Đăng ký',
                      style: TextStyle(color: AppTheme.royalPurple, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
