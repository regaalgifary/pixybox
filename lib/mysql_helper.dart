import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image/image.dart' as img;

/// Helper Koneksi Database MySQL Online (http://pixyboxstudio.biz.id)
/// Seluruh data (users, prices, templates, template_assignments, session_histories)
/// diambil dan disimpan 100% langsung ke database online `pixyboxs_studio`
/// tanpa fallback ke SQLite lokal ataupun file JSON lokal.
class MySqlHelper {
  static const String baseUrl = 'http://pixyboxstudio.biz.id';
  static const String dbApiUrl = '$baseUrl/?path=/api/db';
  static const String migrateApiUrl = '$baseUrl/?path=/api/migrate';

  static http.Client? _customClient;

  /// HTTP Client khusus yang menerima sertifikat SSL self-signed dari cPanel
  static http.Client get _client {
    if (_customClient != null) return _customClient!;
    final ioHttpClient = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) =>
              host == 'pixyboxstudio.biz.id' ||
              host.endsWith('.pixyboxstudio.biz.id');
    _customClient = IOClient(ioHttpClient);
    return _customClient!;
  }

  /// Kirim request aksi ke endpoint database online `pixyboxstudio.biz.id/?path=/api/db`
  static Future<Map<String, dynamic>?> _postAction(
    String action, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 15),
  ]) async {
    try {
      final body = <String, dynamic>{
        'action': action,
        ...?payload,
      };
      final response = await _client
          .post(
            Uri.parse(dbApiUrl),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } else {
        debugPrint(
            'MySqlHelper [$action] HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      debugPrint('MySqlHelper [$action] network error: $e');
    }
    return null;
  }

  /// Membuat gambar PNG template default HD (1200x1800) di memori bila database online belum memiliki template
  static Uint8List _generateDefaultTemplatePng() {
    try {
      const int width = 1200;
      const int height = 1800;
      final image = img.Image(width: width, height: height, numChannels: 4);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          bool inSlot1 = (x >= 90 && x <= 1110 && y >= 100 && y <= 560);
          bool inSlot2 = (x >= 90 && x <= 1110 && y >= 600 && y <= 1060);
          bool inSlot3 = (x >= 90 && x <= 1110 && y >= 1100 && y <= 1560);

          if (inSlot1 || inSlot2 || inSlot3) {
            image.setPixelRgba(x, y, 0, 0, 0, 0);
          } else {
            image.setPixelRgba(x, y, 211, 36, 43, 255);
          }
        }
      }

      img.drawRect(
        image,
        x1: 25,
        y1: 25,
        x2: width - 26,
        y2: height - 26,
        color: img.ColorRgba8(255, 255, 255, 255),
        thickness: 6,
      );

      img.drawRect(
        image,
        x1: 90,
        y1: 100,
        x2: 1110,
        y2: 560,
        color: img.ColorRgba8(255, 255, 255, 180),
        thickness: 3,
      );
      img.drawRect(
        image,
        x1: 90,
        y1: 600,
        x2: 1110,
        y2: 1060,
        color: img.ColorRgba8(255, 255, 255, 180),
        thickness: 3,
      );
      img.drawRect(
        image,
        x1: 90,
        y1: 1100,
        x2: 1110,
        y2: 1560,
        color: img.ColorRgba8(255, 255, 255, 180),
        thickness: 3,
      );

      return Uint8List.fromList(img.encodePng(image));
    } catch (e) {
      debugPrint('Error membuat default template PNG: $e');
      return Uint8List(0);
    }
  }

  /// Inisialisasi & migrasi otomatis skema database + seed data awal di server `pixyboxstudio.biz.id`
  static Future<void> initRemoteDatabase() async {
    try {
      final response = await _client
          .get(
            Uri.parse(migrateApiUrl),
            headers: {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        debugPrint(
            'Database online pixyboxstudio.biz.id siap: ${response.body}');
      }

      // Pastikan template default tersedia di database online jika tabel templates masih kosong
      final remoteTemplatesResp = await _postAction('get_templates', {
        'id_user': 3,
        'role': 'admin',
      });
      if (remoteTemplatesResp != null &&
          remoteTemplatesResp['success'] == true) {
        final List<dynamic> remoteList =
            remoteTemplatesResp['templates'] as List<dynamic>? ?? [];
        if (remoteList.isEmpty) {
          final imgBytes = _generateDefaultTemplatePng();
          if (imgBytes.isNotEmpty) {
            await _postAction(
              'save_template',
              {
                'id_user': 3,
                'name': 'Classic 3-Strip Pixybox',
                'image_base64': base64Encode(imgBytes),
                'template_mode': '4r',
                'slot1_x': 0.075,
                'slot1_y': 0.055,
                'slot1_w': 0.85,
                'slot1_h': 0.255,
                'slot2_x': 0.075,
                'slot2_y': 0.333,
                'slot2_w': 0.85,
                'slot2_h': 0.255,
                'slot3_x': 0.075,
                'slot3_y': 0.611,
                'slot3_w': 0.85,
                'slot3_h': 0.255,
                'slot4_x': 0.575,
                'slot4_y': 0.055,
                'slot4_w': 0.85,
                'slot4_h': 0.255,
                'slot5_x': 0.575,
                'slot5_y': 0.333,
                'slot5_w': 0.85,
                'slot5_h': 0.255,
                'slot6_x': 0.575,
                'slot6_y': 0.611,
                'slot6_w': 0.85,
                'slot6_h': 0.255,
                'assigned_booth_ids': [1, 2, 3],
              },
              const Duration(seconds: 25),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('initRemoteDatabase gagal: $e');
    }
  }

  /// Uji koneksi ke database MySQL `pixyboxstudio.biz.id`
  static Future<bool> testConnection() async {
    final res = await _postAction('test_connection');
    return res != null && res['success'] == true;
  }

  /// Login akun photobox / admin murni dari database online `pixyboxstudio.biz.id`
  static Future<Map<String, dynamic>?> loginUser(
      String username, String password) async {
    final res = await _postAction('login_user', {
      'username': username,
      'password': password,
    });

    if (res != null && res['success'] == true && res['user'] is Map) {
      final userMap = Map<String, dynamic>.from(res['user'] as Map);
      return {
        'id_user': int.parse(userMap['id_user'].toString()),
        'username': userMap['username'].toString(),
        'role': userMap['role'].toString(),
        'alamat_photobox': (userMap['alamat_photobox'] ?? '').toString(),
      };
    }

    return null;
  }

  /// Verifikasi password akun saat ingin kembali ke dashboard (murni dari database online)
  static Future<bool> verifyStaffOrAdminPassword({
    int? idUser,
    String? username,
    required String password,
  }) async {
    final res = await _postAction('verify_password', {
      'id_user': idUser,
      'username': username,
      'password': password,
    });

    if (res != null && res.containsKey('verified')) {
      return res['verified'] == true;
    }

    return false;
  }

  /// Ambil daftar harga pengguna murni dari tabel `prices` di database online `pixyboxstudio.biz.id`
  static Future<List<Map<String, dynamic>>> getPricesForUser(int idUser) async {
    final res = await _postAction('get_prices', {'id_user': idUser});
    if (res != null && res['success'] == true && res['prices'] is List) {
      final List<dynamic> rawPrices = res['prices'] as List<dynamic>;
      if (rawPrices.isNotEmpty) {
        return rawPrices.map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          final count = int.parse(map['print_count'].toString());
          return {
            'print_count': count,
            'price': double.parse(map['price'].toString()),
            'label': (map['label'] ?? '${count}x Cetak').toString(),
          };
        }).toList();
      }
    }
    return [];
  }

  /// Simpan template baru murni ke database online `pixyboxstudio.biz.id`
  static Future<void> saveTemplate({
    required int idUser,
    required String name,
    required List<int> imageData,
    String templateMode = '4r',
    required double slot1X,
    required double slot1Y,
    required double slot1W,
    required double slot1H,
    required double slot2X,
    required double slot2Y,
    required double slot2W,
    required double slot2H,
    required double slot3X,
    required double slot3Y,
    required double slot3W,
    required double slot3H,
    double? slot4X,
    double? slot4Y,
    double? slot4W,
    double? slot4H,
    double? slot5X,
    double? slot5Y,
    double? slot5W,
    double? slot5H,
    double? slot6X,
    double? slot6Y,
    double? slot6W,
    double? slot6H,
    required List<int> assignedBoothIds,
  }) async {
    final res = await _postAction(
      'save_template',
      {
        'id_user': idUser,
        'name': name,
        'image_base64': base64Encode(imageData),
        'template_mode': templateMode,
        'slot1_x': slot1X,
        'slot1_y': slot1Y,
        'slot1_w': slot1W,
        'slot1_h': slot1H,
        'slot2_x': slot2X,
        'slot2_y': slot2Y,
        'slot2_w': slot2W,
        'slot2_h': slot2H,
        'slot3_x': slot3X,
        'slot3_y': slot3Y,
        'slot3_w': slot3W,
        'slot3_h': slot3H,
        'slot4_x': slot4X ?? (slot1X + 0.5),
        'slot4_y': slot4Y ?? slot1Y,
        'slot4_w': slot4W ?? slot1W,
        'slot4_h': slot4H ?? slot1H,
        'slot5_x': slot5X ?? (slot2X + 0.5),
        'slot5_y': slot5Y ?? slot2Y,
        'slot5_w': slot5W ?? slot2W,
        'slot5_h': slot5H ?? slot2H,
        'slot6_x': slot6X ?? (slot3X + 0.5),
        'slot6_y': slot6Y ?? slot3Y,
        'slot6_w': slot6W ?? slot3W,
        'slot6_h': slot6H ?? slot3H,
        'assigned_booth_ids': assignedBoothIds,
      },
      const Duration(seconds: 30),
    );

    if (res == null || res['success'] != true) {
      throw Exception(
          res?['message'] ?? 'Gagal menyimpan template ke database online.');
    }
  }

  /// Ambil template sesuai role dan user murni dari database online `pixyboxstudio.biz.id`
  static Future<List<Map<String, dynamic>>> getTemplatesForUser(
      int idUser, String role) async {
    final res = await _postAction(
      'get_templates',
      {'id_user': idUser, 'role': role},
      const Duration(seconds: 25),
    );

    if (res != null && res['success'] == true && res['templates'] is List) {
      final List<dynamic> rawList = res['templates'] as List<dynamic>;
      final List<Map<String, dynamic>> parsed = [];
      for (final item in rawList) {
        final row = Map<String, dynamic>.from(item as Map);
        final String b64 = (row['image_base64'] ?? '').toString();
        Uint8List bytes = Uint8List(0);
        if (b64.isNotEmpty) {
          try {
            bytes = base64Decode(b64);
          } catch (_) {}
        }

        final double s1x = double.tryParse(row['slot1_x'].toString()) ?? 0.075;
        final double s1y = double.tryParse(row['slot1_y'].toString()) ?? 0.055;
        final double s1w = double.tryParse(row['slot1_w'].toString()) ?? 0.85;
        final double s1h = double.tryParse(row['slot1_h'].toString()) ?? 0.255;
        final double s2x = double.tryParse(row['slot2_x'].toString()) ?? 0.075;
        final double s2y = double.tryParse(row['slot2_y'].toString()) ?? 0.333;
        final double s2w = double.tryParse(row['slot2_w'].toString()) ?? 0.85;
        final double s2h = double.tryParse(row['slot2_h'].toString()) ?? 0.255;
        final double s3x = double.tryParse(row['slot3_x'].toString()) ?? 0.075;
        final double s3y = double.tryParse(row['slot3_y'].toString()) ?? 0.611;
        final double s3w = double.tryParse(row['slot3_w'].toString()) ?? 0.85;
        final double s3h = double.tryParse(row['slot3_h'].toString()) ?? 0.255;

        parsed.add({
          'id_template': int.parse(row['id_template'].toString()),
          'id_user': int.parse(row['id_user'].toString()),
          'name': row['name'].toString(),
          'image_data': bytes,
          'template_mode': (row['template_mode'] ?? '4r').toString(),
          'slot1_x': s1x,
          'slot1_y': s1y,
          'slot1_w': s1w,
          'slot1_h': s1h,
          'slot2_x': s2x,
          'slot2_y': s2y,
          'slot2_w': s2w,
          'slot2_h': s2h,
          'slot3_x': s3x,
          'slot3_y': s3y,
          'slot3_w': s3w,
          'slot3_h': s3h,
          'slot4_x':
              double.tryParse(row['slot4_x']?.toString() ?? '') ?? (s1x + 0.5),
          'slot4_y': double.tryParse(row['slot4_y']?.toString() ?? '') ?? s1y,
          'slot4_w': double.tryParse(row['slot4_w']?.toString() ?? '') ?? s1w,
          'slot4_h': double.tryParse(row['slot4_h']?.toString() ?? '') ?? s1h,
          'slot5_x':
              double.tryParse(row['slot5_x']?.toString() ?? '') ?? (s2x + 0.5),
          'slot5_y': double.tryParse(row['slot5_y']?.toString() ?? '') ?? s2y,
          'slot5_w': double.tryParse(row['slot5_w']?.toString() ?? '') ?? s2w,
          'slot5_h': double.tryParse(row['slot5_h']?.toString() ?? '') ?? s2h,
          'slot6_x':
              double.tryParse(row['slot6_x']?.toString() ?? '') ?? (s3x + 0.5),
          'slot6_y': double.tryParse(row['slot6_y']?.toString() ?? '') ?? s3y,
          'slot6_w': double.tryParse(row['slot6_w']?.toString() ?? '') ?? s3w,
          'slot6_h': double.tryParse(row['slot6_h']?.toString() ?? '') ?? s3h,
        });
      }
      return parsed;
    }

    return [];
  }

  /// Ambil daftar akun booth murni dari database online `pixyboxstudio.biz.id`
  static Future<List<Map<String, dynamic>>> getBoothUsers() async {
    final res = await _postAction('get_booth_users');
    if (res != null && res['success'] == true && res['booths'] is List) {
      final List<dynamic> booths = res['booths'] as List<dynamic>;
      return booths.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return {
          'id_user': int.parse(m['id_user'].toString()),
          'username': m['username'].toString(),
          'alamat_photobox': (m['alamat_photobox'] ?? '').toString(),
        };
      }).toList();
    }
    return [];
  }

  /// Ambil daftar penugasan booth untuk template murni dari database online `pixyboxstudio.biz.id`
  static Future<List<int>> getTemplateAssignments(int idTemplate) async {
    final res = await _postAction('get_template_assignments', {
      'id_template': idTemplate,
    });
    if (res != null &&
        res['success'] == true &&
        res['assigned_booth_ids'] is List) {
      return (res['assigned_booth_ids'] as List<dynamic>)
          .map((e) => int.parse(e.toString()))
          .toList();
    }
    return [];
  }

  /// Hapus template murni dari database online `pixyboxstudio.biz.id`
  static Future<void> deleteTemplate(int idTemplate) async {
    await _postAction('delete_template', {'id_template': idTemplate});
  }

  /// Catat riwayat sesi awal murni ke database online `pixyboxstudio.biz.id`
  static Future<void> createSessionHistory({
    required String orderId,
    required int idUser,
    int? idTemplate,
    String? templateName,
    required int printCount,
    required double totalPrice,
    String paymentType = 'qris',
  }) async {
    await _postAction('create_session_history', {
      'order_id': orderId,
      'id_user': idUser,
      'id_template': idTemplate,
      'template_name': templateName,
      'print_count': printCount,
      'total_price': totalPrice,
      'payment_type': paymentType,
    });
  }

  /// Update status pembayaran dan sesi murni di database online `pixyboxstudio.biz.id`
  static Future<void> updateSessionStatus({
    required String orderId,
    required String paymentStatus,
    String? sessionStatus,
    int? idTemplate,
    String? templateName,
  }) async {
    await _postAction('update_session_status', {
      'order_id': orderId,
      'payment_status': paymentStatus,
      'session_status': sessionStatus,
      'id_template': idTemplate,
      'template_name': templateName,
    });
  }

  /// Ambil riwayat sesi photobox murni dari database online `pixyboxstudio.biz.id`
  static Future<List<Map<String, dynamic>>> getSessionHistories({
    int? idUser,
    int limit = 50,
  }) async {
    final res = await _postAction('get_session_histories', {
      'id_user': idUser,
      'limit': limit,
    });

    if (res != null && res['success'] == true && res['histories'] is List) {
      final List<dynamic> list = res['histories'] as List<dynamic>;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }

    return [];
  }
}
