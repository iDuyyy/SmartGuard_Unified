import 'package:flutter/material.dart';
import 'core/app_config.dart';
import 'core/app_theme.dart';
import 'core/session_manager.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/home_shell.dart';

/// Dùng để điều hướng từ ngoài cây widget (ví dụ khi máy chủ báo 401).
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.init();
  await SessionManager.init();

  SessionManager.onSessionExpired = () {
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
    appMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text('Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.'),
      ),
    );
  };

  runApp(const SmartGuardApp());
}

class SmartGuardApp extends StatelessWidget {
  const SmartGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartGuard Unified',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: SessionManager.isLoggedIn ? const HomeShell() : const WelcomeScreen(),
    );
  }
}
