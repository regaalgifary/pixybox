import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Model untuk preset filter foto photobooth
class PhotoFilterPreset {
  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final List<double> matrix;

  const PhotoFilterPreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.matrix,
  });
}

/// Matrix identitas (100% warna asli tanpa efek)
const List<double> kIdentityColorMatrix = [
  1.0, 0.0, 0.0, 0.0, 0.0,
  0.0, 1.0, 0.0, 0.0, 0.0,
  0.0, 0.0, 1.0, 0.0, 0.0,
  0.0, 0.0, 0.0, 1.0, 0.0,
];

/// Daftar preset filter populer photobooth
const List<PhotoFilterPreset> kPhotoFilterPresets = [
  PhotoFilterPreset(
    id: 'normal',
    name: 'NORMAL',
    subtitle: 'Asli',
    icon: Icons.auto_fix_normal_rounded,
    accentColor: Colors.white,
    matrix: kIdentityColorMatrix,
  ),
  PhotoFilterPreset(
    id: 'bright',
    name: 'BRIGHT',
    subtitle: 'Kecerahan',
    icon: Icons.wb_sunny_outlined,
    accentColor: Colors.amber,
    matrix: [
      1.10, 0.00, 0.00, 0.0, 22.0,
      0.00, 1.10, 0.00, 0.0, 22.0,
      0.00, 0.00, 1.10, 0.0, 22.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'bw',
    name: 'B&W',
    subtitle: 'Monokrom',
    icon: Icons.filter_b_and_w_rounded,
    accentColor: Colors.white70,
    matrix: [
      0.33, 0.59, 0.11, 0.0, 0.0,
      0.33, 0.59, 0.11, 0.0, 0.0,
      0.33, 0.59, 0.11, 0.0, 0.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'warm',
    name: 'WARM',
    subtitle: 'Hangat',
    icon: Icons.wb_sunny_rounded,
    accentColor: Colors.amberAccent,
    matrix: [
      1.08, 0.05, 0.00, 0.0, 10.0,
      0.00, 1.02, 0.00, 0.0, 5.0,
      0.00, 0.00, 0.88, 0.0, -8.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'cool',
    name: 'COOL',
    subtitle: 'Sinematik',
    icon: Icons.ac_unit_rounded,
    accentColor: Colors.lightBlueAccent,
    matrix: [
      0.92, 0.00, 0.00, 0.0, -5.0,
      0.00, 1.00, 0.00, 0.0, 0.0,
      0.05, 0.05, 1.18, 0.0, 15.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'vintage',
    name: 'VINTAGE',
    subtitle: 'Sepia',
    icon: Icons.camera_roll_rounded,
    accentColor: Color(0xFFE0A96D),
    matrix: [
      0.393, 0.769, 0.189, 0.0, 0.0,
      0.349, 0.686, 0.168, 0.0, 0.0,
      0.272, 0.534, 0.131, 0.0, 0.0,
      0.0,   0.0,   0.0,   1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'vivid',
    name: 'VIVID',
    subtitle: 'Cerah',
    icon: Icons.auto_awesome_rounded,
    accentColor: Colors.orangeAccent,
    matrix: [
      1.25,  -0.10, -0.10, 0.0, 0.0,
      -0.10, 1.25,  -0.10, 0.0, 0.0,
      -0.10, -0.10, 1.25,  0.0, 0.0,
      0.0,   0.0,   0.0,   1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'fade',
    name: 'FADE',
    subtitle: 'Matte Film',
    icon: Icons.cloud_outlined,
    accentColor: Colors.tealAccent,
    matrix: [
      0.85, 0.08, 0.08, 0.0, 25.0,
      0.08, 0.85, 0.08, 0.0, 25.0,
      0.08, 0.08, 0.85, 0.0, 25.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
  PhotoFilterPreset(
    id: 'rosy',
    name: 'ROSY',
    subtitle: 'Blush Pink',
    icon: Icons.favorite_rounded,
    accentColor: Colors.pinkAccent,
    matrix: [
      1.12, 0.00, 0.05, 0.0, 14.0,
      0.00, 1.00, 0.04, 0.0, 0.0,
      0.04, 0.00, 1.05, 0.0, 10.0,
      0.0,  0.0,  0.0,  1.0, 0.0,
    ],
  ),
];

/// Menghitung matrix warna terinterpolasi berdasarkan intensitas slider (0.0 s/d 1.0)
/// serta penyesuaian kecerahan (-1.0 s/d +1.0)
List<double> getInterpolatedColorMatrix(
  String filterId,
  double intensity, {
  double brightness = 0.0,
}) {
  List<double> baseMatrix;

  if (filterId == 'normal' || intensity <= 0.0) {
    baseMatrix = List<double>.from(kIdentityColorMatrix);
  } else {
    final targetPreset = kPhotoFilterPresets.firstWhere(
      (p) => p.id == filterId,
      orElse: () => kPhotoFilterPresets.first,
    );

    if (intensity >= 1.0) {
      baseMatrix = List<double>.from(targetPreset.matrix);
    } else {
      final t = intensity.clamp(0.0, 1.0);
      final target = targetPreset.matrix;
      baseMatrix = List<double>.generate(20, (i) {
        final idVal = kIdentityColorMatrix[i];
        final targetVal = target[i];
        return idVal + (targetVal - idVal) * t;
      });
    }
  }

  // Terapkan penyesuaian kecerahan (brightness) jika ada (-1.0 s/d +1.0)
  if (brightness != 0.0) {
    final b = brightness.clamp(-1.0, 1.0);
    final offset = b * 50.0; // Rentang offset pencahayaan
    final gain = b > 0 ? (b * 0.10) : (b * 0.05);

    baseMatrix[0] = baseMatrix[0] + gain;
    baseMatrix[6] = baseMatrix[6] + gain;
    baseMatrix[12] = baseMatrix[12] + gain;

    baseMatrix[4] = baseMatrix[4] + offset;
    baseMatrix[9] = baseMatrix[9] + offset;
    baseMatrix[14] = baseMatrix[14] + offset;
  }

  return baseMatrix;
}

/// Menerapkan color matrix langsung ke image bytes (img.Image) sebelum cetak PDF
void applyColorMatrixToImage(img.Image image, List<double> matrix) {
  final m00 = matrix[0], m01 = matrix[1], m02 = matrix[2], m04 = matrix[4];
  final m10 = matrix[5], m11 = matrix[6], m12 = matrix[7], m14 = matrix[9];
  final m20 = matrix[10], m21 = matrix[11], m22 = matrix[12], m24 = matrix[14];

  for (final pixel in image) {
    final r = pixel.r;
    final g = pixel.g;
    final b = pixel.b;

    pixel.r = (r * m00 + g * m01 + b * m02 + m04).clamp(0, 255);
    pixel.g = (r * m10 + g * m11 + b * m12 + m14).clamp(0, 255);
    pixel.b = (r * m20 + g * m21 + b * m22 + m24).clamp(0, 255);
  }
}
