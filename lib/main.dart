import 'package:flutter/material.dart';
import 'screens/welcome_screen.dart';

import 'package:window_manager/window_manager.dart';
import 'payment_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await PaymentConfig.loadConfig();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixybox Desktop App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.grey,
          surface: Color(0xFF161616),
          background: Color(0xFF0F0F0F),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const WelcomeScreen(),
    );
  }
}
