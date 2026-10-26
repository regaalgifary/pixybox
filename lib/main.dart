import 'package:flutter/material.dart';
import 'screens/welcome_screen.dart';

import 'package:window_manager/window_manager.dart';
import 'payment_config.dart';
import 'price_config.dart';
import 'database_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.initializeFfi();
  await DatabaseHelper.initDatabase();
  await windowManager.ensureInitialized();
  await PaymentConfig.loadConfig();
  await PriceConfig.ensureInitialized();
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
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        fontFamily: 'Segoe UI',
      ),
      home: const WelcomeScreen(),
    );
  }
}
