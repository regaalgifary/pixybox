import 'package:flutter/material.dart';
import 'login_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  static const Color kPrimaryRed = Color(0xFFD3242B);
  static const Color kDarkRed = Color(0xFF94151A);

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;

            return Stack(
              fit: StackFit.expand,
              children: [
                // Subtle soft pinkish-red radial glow in the center
                Center(
                  child: Container(
                    width: w * 0.65,
                    height: h * 0.75,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          kPrimaryRed.withAlpha(24),
                          kPrimaryRed.withAlpha(10),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),

                // 5 Sparkle 4-point stars matching the reference layout
                Positioned(
                  left: w * 0.068,
                  top: h * 0.20,
                  child: const FourPointStar(size: 46, color: kPrimaryRed),
                ),
                Positioned(
                  left: w * 0.278,
                  top: h * 0.145,
                  child: const FourPointStar(size: 24, color: kPrimaryRed),
                ),
                Positioned(
                  right: w * 0.222,
                  top: h * 0.215,
                  child: const FourPointStar(size: 30, color: kPrimaryRed),
                ),
                Positioned(
                  left: w * 0.192,
                  bottom: h * 0.17,
                  child: const FourPointStar(size: 32, color: kPrimaryRed),
                ),
                Positioned(
                  right: w * 0.112,
                  bottom: h * 0.34,
                  child: const FourPointStar(size: 38, color: kPrimaryRed),
                ),

                // Main Center Content
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 16),
                      // Double-lined oval PIXYBOX Logo
                      const PixyboxOvalLogo(
                        width: 540,
                        height: 200,
                        fontSize: 64,
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'PHOTO BOOTH',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 7.0,
                          color: kPrimaryRed,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Sistem Aplikasi Software Photobox Desktop',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: kPrimaryRed.withAlpha(170),
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 54),

                      // 3D Red Pill Button (START / LOGIN)
                      _Red3DPillButton(
                        label: 'START',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const LoginScreen()),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Red3DPillButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _Red3DPillButton({
    required this.label,
    required this.onTap,
  });

  @override
  State<_Red3DPillButton> createState() => _Red3DPillButtonState();
}

class _Red3DPillButtonState extends State<_Red3DPillButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 240,
          height: 64,
          transform: Matrix4.translationValues(0, _isPressed ? 4 : 0, 0),
          decoration: BoxDecoration(
            color: WelcomeScreen.kPrimaryRed,
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: WelcomeScreen.kDarkRed, width: 1.5),
            boxShadow: _isPressed
                ? [
                    const BoxShadow(
                      color: WelcomeScreen.kDarkRed,
                      offset: Offset(0, 2),
                      blurRadius: 0,
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: WelcomeScreen.kDarkRed,
                      offset: Offset(0, 6),
                      blurRadius: 0,
                    ),
                    BoxShadow(
                      color: WelcomeScreen.kPrimaryRed.withAlpha(45),
                      offset: const Offset(0, 12),
                      blurRadius: 20,
                    ),
                  ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                letterSpacing: 3.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable double-lined red oval PIXYBOX logo matching the reference image
class PixyboxOvalLogo extends StatelessWidget {
  final double width;
  final double height;
  final double fontSize;
  final Color color;

  const PixyboxOvalLogo({
    super.key,
    this.width = 560,
    this.height = 205,
    this.fontSize = 68,
    this.color = const Color(0xFFD3242B),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _DoubleOvalPainter(color: color),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              'PIXYBOX',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: 6.0,
                color: color,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoubleOvalPainter extends CustomPainter {
  final Color color;

  _DoubleOvalPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final outerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2
      ..isAntiAlias = true;

    final innerPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..isAntiAlias = true;

    final outerRect = Rect.fromLTWH(
      3,
      3,
      size.width - 6,
      size.height - 6,
    );
    final innerRect = outerRect.deflate(6.5);

    canvas.drawOval(outerRect, outerPaint);
    canvas.drawOval(innerRect, innerPaint);
  }

  @override
  bool shouldRepaint(covariant _DoubleOvalPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Reusable 4-point sparkle star widget matching the reference image
class FourPointStar extends StatelessWidget {
  final double size;
  final Color color;

  const FourPointStar({
    super.key,
    required this.size,
    this.color = const Color(0xFFD3242B),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _FourPointStarPainter(color: color),
      ),
    );
  }
}

class _FourPointStarPainter extends CustomPainter {
  final Color color;

  _FourPointStarPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double r = size.width * 0.16; // inward curve control radius

    final path = Path()
      ..moveTo(cx, 0) // Top point
      ..quadraticBezierTo(cx + r, cy - r, size.width, cy) // Right point
      ..quadraticBezierTo(cx + r, cy + r, cx, size.height) // Bottom point
      ..quadraticBezierTo(cx - r, cy + r, 0, cy) // Left point
      ..quadraticBezierTo(cx - r, cy - r, cx, 0) // Back to Top point
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FourPointStarPainter oldDelegate) =>
      oldDelegate.color != color;
}
