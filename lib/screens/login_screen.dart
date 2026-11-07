import 'package:flutter/material.dart';
import '../mysql_helper.dart';
import 'settings_screen.dart';
import 'welcome_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kDarkRed = Color(0xFF94151A);
  static const Color kSoftRedBg = Color(0xFFFFF5F5);
  static const Color kBorderRed = Color(0xFFF3C6C8);

  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Username dan Password tidak boleh kosong';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Validasi database
    final user = await MySqlHelper.loginUser(username, password);

    setState(() {
      _isLoading = false;
    });

    if (user != null) {
      if (mounted) {
        // Navigasi ke Dashboard Pengaturan dengan passing data user
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (context) => SettingsScreen(user: user),
          ),
          (route) => false,
        );
      }
    } else {
      setState(() {
        _errorMessage = 'Username atau Password salah';
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDFC),
          border: Border.all(color: kPrimaryRed, width: 6),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Soft radial glow
            Center(
              child: Container(
                width: 650,
                height: 650,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      kPrimaryRed.withAlpha(20),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Decorative 4-point stars
            const Positioned(
              left: 80,
              top: 110,
              child: FourPointStar(size: 42, color: kPrimaryRed),
            ),
            const Positioned(
              right: 140,
              top: 120,
              child: FourPointStar(size: 28, color: kPrimaryRed),
            ),
            const Positioned(
              left: 160,
              bottom: 100,
              child: FourPointStar(size: 30, color: kPrimaryRed),
            ),
            const Positioned(
              right: 110,
              bottom: 160,
              child: FourPointStar(size: 36, color: kPrimaryRed),
            ),

            // Back button
            Positioned(
              top: 20,
              left: 20,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: kPrimaryRed, size: 28),
                tooltip: 'Kembali',
                onPressed: () => Navigator.pop(context),
              ),
            ),

            // Login Card
            Center(
              child: SingleChildScrollView(
                child: Container(
                  width: 450,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: kPrimaryRed, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: kPrimaryRed.withAlpha(30),
                        blurRadius: 30,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: PixyboxOvalLogo(
                          width: 240,
                          height: 86,
                          fontSize: 28,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'LOGIN BOOTH',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3,
                          color: kPrimaryRed,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Masuk ke Akun Unit Photobox Anda',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: kPrimaryRed.withAlpha(170),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 28),

                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: kSoftRedBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: kPrimaryRed.withAlpha(120)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: kPrimaryRed),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: kPrimaryRed,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Input Username
                      TextField(
                        controller: _usernameController,
                        style: const TextStyle(
                          color: Color(0xFF1F1F1F),
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.person_outline, color: kPrimaryRed),
                          labelText: 'Username',
                          labelStyle: TextStyle(color: kPrimaryRed.withAlpha(170)),
                          filled: true,
                          fillColor: kSoftRedBg,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Input Password
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        style: const TextStyle(
                          color: Color(0xFF1F1F1F),
                          fontWeight: FontWeight.w600,
                        ),
                        onSubmitted: (_) {
                          if (!_isLoading) _handleLogin();
                        },
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.key_outlined, color: kPrimaryRed),
                          labelText: 'Password',
                          labelStyle: TextStyle(color: kPrimaryRed.withAlpha(170)),
                          filled: true,
                          fillColor: kSoftRedBg,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kBorderRed, width: 1.5),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: kPrimaryRed, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Tombol Login (3D Red Pill Style)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: const [
                            BoxShadow(
                              color: kDarkRed,
                              offset: Offset(0, 4),
                              blurRadius: 0,
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _handleLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kPrimaryRed,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: kPrimaryRed.withAlpha(140),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                            ),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'MASUK',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2.5,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: kSoftRedBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kBorderRed),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Info Akun Lokal (Default):',
                              style: TextStyle(
                                color: kPrimaryRed,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '• Admin: admin_pixy  |  Pass: admin123\n• Booth: photobox_01  |  Pass: password123',
                              style: TextStyle(
                                color: kPrimaryRed.withAlpha(190),
                                fontSize: 11,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
