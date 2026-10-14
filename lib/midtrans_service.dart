import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class MidtransService {
  static Map<String, dynamic>? _keysCache;

  static void _ensureKeysLoaded() {
    if (_keysCache != null) return;
    try {
      final file = File('payment_keys.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync());
        _keysCache = data['midtrans'] as Map<String, dynamic>? ?? {};
      } else {
        _keysCache = {};
      }
    } catch (e) {
      debugPrint('Error reading payment_keys.json: $e');
      _keysCache = {};
    }
  }

  // Mode Environment: atur ke false untuk Sandbox (Testing), true untuk Production (Live)
  static bool get isProduction {
    _ensureKeysLoaded();
    return _keysCache?['is_production'] as bool? ?? false;
  }

  // Getter otomatis sesuai mode aktif
  static String get merchantId {
    _ensureKeysLoaded();
    return isProduction
        ? (_keysCache?['prod_merchant_id'] as String? ?? '')
        : (_keysCache?['sandbox_merchant_id'] as String? ?? '');
  }

  static String get clientKey {
    _ensureKeysLoaded();
    return isProduction
        ? (_keysCache?['prod_client_key'] as String? ?? '')
        : (_keysCache?['sandbox_client_key'] as String? ?? '');
  }

  static String get _serverKey {
    _ensureKeysLoaded();
    return isProduction
        ? (_keysCache?['prod_server_key'] as String? ?? '')
        : (_keysCache?['sandbox_server_key'] as String? ?? '');
  }

  static String get _baseUrl => isProduction
      ? 'https://api.midtrans.com/v2'
      : 'https://api.sandbox.midtrans.com/v2';

  // Persistent HTTP client for connection reuse & Keep-Alive
  static final http.Client _client = http.Client();

  /// Melakukan request QRIS ke Midtrans
  static Future<Map<String, dynamic>?> generateQRIS({
    required String orderId,
    required int amount,
    String itemName = 'PixyBox Payment',
  }) async {
    // Gunakan Server Key untuk otorisasi Basic Auth
    final String basicAuth = 'Basic ${base64Encode(utf8.encode('$_serverKey:'))}';
    
    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl/charge'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': basicAuth,
        },
        body: jsonEncode({
          "payment_type": "qris",
          "transaction_details": {
            "order_id": orderId,
            "gross_amount": amount,
          },
          "item_details": [
            {
              "id": "print_service",
              "price": amount,
              "quantity": 1,
              "name": itemName,
            }
          ],
          "qris": {
            "acquirer": "gopay"
          }
        }),
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final actions = data['actions'] as List?;
        String? qrUrl;
        if (actions != null) {
          for (final action in actions) {
            if (action is Map && action['name'] == 'generate-qr-code') {
              qrUrl = action['url'];
              break;
            }
          }
        }
        
        if (qrUrl != null) {
          debugPrint('=================== MIDTRANS QRIS MPM ===================');
          debugPrint('Order ID       : $orderId');
          debugPrint('QR MPM URL     : $qrUrl');
          debugPrint('Simulator Link : https://simulator.sandbox.midtrans.com/v2/qris/index');
          debugPrint('PETUNJUK TEST  : Salin "QR MPM URL" di atas dan tempel di kolom "QR Code Image Url" pada Simulator');
          debugPrint('=========================================================');
          return {
            'order_id': orderId,
            'qr_url': qrUrl,
            'qr_string': data['qr_string'],
          };
        } else {
          debugPrint('Actions QR tidak ditemukan: ${response.body}');
        }
      } else {
        debugPrint('Gagal generate QRIS: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error generateQRIS: $e');
    }
    return null;
  }

  /// Mengecek status pembayaran (Polling)
  static Future<String> checkPaymentStatus(String orderId) async {
    final String basicAuth = 'Basic ${base64Encode(utf8.encode('$_serverKey:'))}';
    
    try {
      final response = await _client.get(
        Uri.parse('$_baseUrl/$orderId/status'),
        headers: {
          'Accept': 'application/json',
          'Authorization': basicAuth,
        },
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Status yang sukses biasanya 'settlement' atau 'capture'
        return data['transaction_status'] ?? 'pending';
      }
    } catch (e) {
      debugPrint('CheckPaymentStatus notice ($orderId): $e');
    }
    return 'pending';
  }
}
