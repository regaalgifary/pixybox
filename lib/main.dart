import 'dart:io';
import 'package:flutter/material.dart';
import 'screens/welcome_screen.dart';

import 'package:window_manager/window_manager.dart';
import 'payment_config.dart';
import 'mysql_helper.dart';

/// Mengizinkan sertifikat SSL (termasuk self-signed dari cPanel AutoSSL)
/// untuk domain pixyboxstudio.biz.id agar koneksi HTTPS tidak ditolak oleh BoringSSL.
class PixyboxHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) {
        return host == 'pixyboxstudio.biz.id' ||
            host.endsWith('.pixyboxstudio.biz.id');
      };
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = PixyboxHttpOverrides();
  await MySqlHelper.initRemoteDatabase();
  await windowManager.ensureInitialized();
  await PaymentConfig.loadConfig();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const Color primaryRed = Color(0xFFD3242B);
  static const Color darkRed = Color(0xFF94151A);
  static const Color lightRedBg = Color(0xFFFFF5F5);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixybox Desktop App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: primaryRed,
          onPrimary: Colors.white,
          secondary: darkRed,
          onSecondary: Colors.white,
          surface: Colors.white,
          onSurface: Color(0xFF1F1F1F),
        ),
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Segoe UI',
      ),
      home: const WelcomeScreen(),
    );
  }
}
