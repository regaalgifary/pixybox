import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class DokuService {
  static Map<String, dynamic>? _keysCache;

  static void _ensureKeysLoaded() {
    if (_keysCache != null) return;
    try {
      final file = File('payment_keys.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync());
        _keysCache = data['doku'] as Map<String, dynamic>? ?? {};
      } else {
        _keysCache = {};
      }
    } catch (e) {
      debugPrint('Error reading payment_keys.json: $e');
      _keysCache = {};
    }
  }

  // Mode Environment: true untuk Production (Live), false untuk Sandbox (Testing)
  static bool get isProduction {
    _ensureKeysLoaded();
    return _keysCache?['is_production'] as bool? ?? true;
  }

  static String get clientId {
    _ensureKeysLoaded();
    return _keysCache?['client_id'] as String? ?? '';
  }

  static String get secretKey {
    _ensureKeysLoaded();
    return _keysCache?['secret_key'] as String? ?? '';
  }

  static String get apiKey {
    _ensureKeysLoaded();
    return _keysCache?['api_key'] as String? ?? '';
  }

  static String get _baseUrl => isProduction
      ? 'https://api.doku.com'
      : 'https://api-sandbox.doku.com';

  static final http.Client _client = http.Client();

  /// Membuat HMAC-SHA256 Signature untuk HTTP POST (menggunakan Digest Body)
  static String _generatePostSignature({
    required String clientId,
    required String secretKey,
    required String requestId,
    required String requestTimestamp,
    required String targetPath,
    required String jsonBody,
  }) {
    final digestBytes = sha256.convert(utf8.encode(jsonBody)).bytes;
    final digestBase64 = base64Encode(digestBytes);

    final signatureComponents =
        'Client-Id:$clientId\n'
        'Request-Id:$requestId\n'
        'Request-Timestamp:$requestTimestamp\n'
        'Request-Target:$targetPath\n'
        'Digest:$digestBase64';

    final hmac = Hmac(sha256, utf8.encode(secretKey));
    final signatureBytes = hmac.convert(utf8.encode(signatureComponents)).bytes;
    return 'HMACSHA256=${base64Encode(signatureBytes)}';
  }

  /// Membuat HMAC-SHA256 Signature untuk HTTP GET (tanpa Digest Body)
  static String _generateGetSignature({
    required String clientId,
    required String secretKey,
    required String requestId,
    required String requestTimestamp,
    required String targetPath,
  }) {
    final signatureComponents =
        'Client-Id:$clientId\n'
        'Request-Id:$requestId\n'
        'Request-Timestamp:$requestTimestamp\n'
        'Request-Target:$targetPath';

    final hmac = Hmac(sha256, utf8.encode(secretKey));
    final signatureBytes = hmac.convert(utf8.encode(signatureComponents)).bytes;
    return 'HMACSHA256=${base64Encode(signatureBytes)}';
  }

  /// Melakukan request transaksi pembayaran QRIS / Checkout ke DOKU
  static Future<Map<String, dynamic>?> generateQRIS({
    required String orderId,
    required int amount,
    String itemName = 'PixyBox Payment',
  }) async {
    const targetPath = '/checkout/v1/payment';
    final requestId = 'REQ-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final requestTimestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

    // Coba dengan filter QRIS terlebih dahulu
    Map<String, dynamic>? result = await _callCheckoutApi(
      orderId: orderId,
      amount: amount,
      requestId: requestId,
      requestTimestamp: requestTimestamp,
      targetPath: targetPath,
      filterQris: true,
    );

    // Jika kanal QRIS belum aktif di akun DOKU merchant, fallback ke all channels
    if (result == null) {
      debugPrint('Kanal QRIS belum aktif di DOKU, mencoba fallback ke semua metode pembayaran aktif...');
      result = await _callCheckoutApi(
        orderId: orderId,
        amount: amount,
        requestId: requestId,
        requestTimestamp: requestTimestamp,
        targetPath: targetPath,
        filterQris: false,
      );
    }

    return result;
  }

  static Future<Map<String, dynamic>?> _callCheckoutApi({
    required String orderId,
    required int amount,
    required String requestId,
    required String requestTimestamp,
    required String targetPath,
    required bool filterQris,
  }) async {
    final Map<String, dynamic> bodyMap = {
      "order": {
        "amount": amount,
        "invoice_number": orderId,
        "currency": "IDR",
        "callback_url": "https://doku.com",
        "auto_redirect": false,
      },
      "payment": {
        "payment_due_date": 60,
        if (filterQris) "payment_method_types": ["QRIS"],
      }
    };

    final rawBody = jsonEncode(bodyMap);
    final signature = _generatePostSignature(
      clientId: clientId,
      secretKey: secretKey,
      requestId: requestId,
      requestTimestamp: requestTimestamp,
      targetPath: targetPath,
      jsonBody: rawBody,
    );

    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl$targetPath'),
        headers: {
          'Content-Type': 'application/json',
          'Client-Id': clientId,
          'Request-Id': requestId,
          'Request-Timestamp': requestTimestamp,
          'Signature': signature,
        },
        body: rawBody,
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final payment = data['response']?['payment'] as Map<String, dynamic>?;
        final paymentUrl = payment?['url'] as String?;
        final qrContent = payment?['qr_content'] ?? payment?['qr_string'];

        if (paymentUrl != null || qrContent != null) {
          debugPrint('===================== DOKU PAYMENT =====================');
          debugPrint('Order ID       : $orderId');
          debugPrint('Payment URL    : $paymentUrl');
          debugPrint('QR Content     : $qrContent');
          debugPrint('========================================================');

          return {
            'order_id': orderId,
            'qr_url': paymentUrl,
            'qr_string': qrContent?.toString(),
            'payment_url': paymentUrl,
          };
        } else {
          debugPrint('DOKU payment url/qr tidak ditemukan: ${response.body}');
        }
      } else {
        debugPrint('DOKU generate payment error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error generate DOKU payment: $e');
    }
    return null;
  }

  /// Mengecek status pembayaran DOKU via Inquiry API
  static Future<String> checkPaymentStatus(String orderId) async {
    final targetPath = '/orders/v1/status/$orderId';
    final requestId = 'REQ-STATUS-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final requestTimestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

    final signature = _generateGetSignature(
      clientId: clientId,
      secretKey: secretKey,
      requestId: requestId,
      requestTimestamp: requestTimestamp,
      targetPath: targetPath,
    );

    try {
      final response = await _client.get(
        Uri.parse('$_baseUrl$targetPath'),
        headers: {
          'Client-Id': clientId,
          'Request-Id': requestId,
          'Request-Timestamp': requestTimestamp,
          'Signature': signature,
        },
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final transactionStatus = data['transaction']?['status']?.toString().toUpperCase();
        final orderStatus = data['order']?['status']?.toString().toUpperCase();

        // Status lunas / berhasil
        if (transactionStatus == 'SUCCESS' ||
            transactionStatus == 'SETTLEMENT' ||
            orderStatus == 'SUCCESS' ||
            orderStatus == 'SETTLEMENT') {
          return 'settlement';
        }

        // Status gagal atau kadaluarsa
        if (transactionStatus == 'FAILED' ||
            transactionStatus == 'EXPIRED' ||
            orderStatus == 'EXPIRED' ||
            orderStatus == 'FAILED') {
          return 'expire';
        }

        return 'pending';
      }
    } catch (e) {
      debugPrint('Doku checkPaymentStatus notice ($orderId): $e');
    }
    return 'pending';
  }
}
