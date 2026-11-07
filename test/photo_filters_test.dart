import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixybox/photo_filters.dart';

void main() {
  group('Photo Filters Unit Tests', () {
    test('kPhotoFilterPresets contains expected presets', () {
      expect(kPhotoFilterPresets.length, equals(9));
      final ids = kPhotoFilterPresets.map((p) => p.id).toList();
      expect(ids, containsAll(['normal', 'bright', 'bw', 'warm', 'cool', 'vintage', 'vivid', 'fade', 'rosy']));
    });

    test('getInterpolatedColorMatrix with brightness increases color offset', () {
      final matrix = getInterpolatedColorMatrix('normal', 1.0, brightness: 0.5);
      // Red, Green, Blue offset index 4, 9, 14 should be +25.0
      expect(matrix[4], equals(25.0));
      expect(matrix[9], equals(25.0));
      expect(matrix[14], equals(25.0));
    });

    test('getInterpolatedColorMatrix at 0 intensity returns identity', () {
      final matrix = getInterpolatedColorMatrix('bw', 0.0);
      expect(matrix, equals(kIdentityColorMatrix));
    });

    test('getInterpolatedColorMatrix at 1.0 intensity returns target matrix', () {
      final bwPreset = kPhotoFilterPresets.firstWhere((p) => p.id == 'bw');
      final matrix = getInterpolatedColorMatrix('bw', 1.0);
      expect(matrix, equals(bwPreset.matrix));
    });

    test('getInterpolatedColorMatrix at 0.5 intensity interpolates halfway', () {
      final matrix = getInterpolatedColorMatrix('bw', 0.5);
      // First element: 1.0 + (0.33 - 1.0) * 0.5 = 1.0 - 0.335 = 0.665
      expect(matrix[0], closeTo(0.665, 0.001));
    });

    test('applyColorMatrixToImage modifies image pixels accurately', () {
      final testImg = img.Image(width: 2, height: 2);
      for (final p in testImg) {
        p.r = 200;
        p.g = 100;
        p.b = 50;
      }

      // Apply B&W matrix
      final bwMatrix = getInterpolatedColorMatrix('bw', 1.0);
      applyColorMatrixToImage(testImg, bwMatrix);

      final p0 = testImg.getPixel(0, 0);
      // Expected gray: 200*0.33 + 100*0.59 + 50*0.11 = 66 + 59 + 5.5 = 130.5
      expect(p0.r, closeTo(130, 2));
      expect(p0.g, closeTo(130, 2));
      expect(p0.b, closeTo(130, 2));
    });
  });
}
