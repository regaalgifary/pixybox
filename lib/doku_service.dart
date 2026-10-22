import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/signers/rsa_signer.dart';
import 'package:pointycastle/digests/sha256.dart';

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

  static String get merchantId {
    _ensureKeysLoaded();
    return _keysCache?['merchant_id'] as String? ?? '112621';
  }

  static String get terminalId {
    _ensureKeysLoaded();
    return _keysCache?['terminal_id'] as String? ?? 'A01';
  }

  static String get rsaPrivateKeyFile {
    _ensureKeysLoaded();
    return _keysCache?['rsa_private_key_file'] as String? ?? 'doku_rsa_private.pem';
  }

  static String get _baseUrl => isProduction
      ? 'https://api.doku.com'
      : 'https://api-sandbox.doku.com';

  static final http.Client _client = http.Client();

  // Cache Token B2B SNAP
  static String? _cachedAccessToken;
  static DateTime? _tokenExpiry;

  // Cache RSA Private Key
  static RSAPrivateKey? _cachedPrivateKey;

  static RSAPrivateKey? _getPrivateKey() {
    if (_cachedPrivateKey != null) return _cachedPrivateKey;
    try {
      final file = File(rsaPrivateKeyFile);
      if (!file.existsSync()) {
        debugPrint('File RSA Private Key tidak ditemukan: $rsaPrivateKeyFile');
        return null;
      }
      final pem = file.readAsStringSync();
      final lines = pem.split('\n').where((l) => !l.startsWith('---') && l.trim().isNotEmpty).join();
      final der = base64Decode(lines);
      final p = ASN1Parser(der);
      final seq = p.nextObject() as ASN1Sequence;
      final octet = seq.elements![2] as ASN1OctetString;
      final rsaP = ASN1Parser(octet.valueBytes!);
      final rsaSeq = rsaP.nextObject() as ASN1Sequence;
      final modulus = (rsaSeq.elements![1] as ASN1Integer).integer!;
      final privateExponent = (rsaSeq.elements![3] as ASN1Integer).integer!;
      final pVal = (rsaSeq.elements![4] as ASN1Integer).integer!;
      final qVal = (rsaSeq.elements![5] as ASN1Integer).integer!;
      _cachedPrivateKey = RSAPrivateKey(modulus, privateExponent, pVal, qVal);
      return _cachedPrivateKey;
    } catch (e) {
      debugPrint('Error parsing RSA private key: $e');
      return null;
    }
  }

  /// Mendapatkan Access Token SNAP B2B (dengan caching selama masih valid)
  static Future<String?> _getAccessToken() async {
    if (_cachedAccessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedAccessToken;
    }

    final rsaKey = _getPrivateKey();
    if (rsaKey == null) {
      debugPrint('DOKU SNAP: Private key tidak tersedia, tidak bisa meminta token');
      return null;
    }

    final timestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';
    final stringToSign = '$clientId|$timestamp';

    try {
      final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
      signer.init(true, PrivateKeyParameter<RSAPrivateKey>(rsaKey));
      final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(stringToSign)));
      final signatureBase64 = base64Encode(sig.bytes);

      final response = await _client.post(
        Uri.parse('$_baseUrl/authorization/v1/access-token/b2b'),
        headers: {
          'Content-Type': 'application/json',
          'X-TIMESTAMP': timestamp,
          'X-CLIENT-KEY': clientId,
          'X-SIGNATURE': signatureBase64,
        },
        body: jsonEncode({'grantType': 'client_credentials'}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['accessToken'] as String?;
        final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 900;
        if (token != null) {
          _cachedAccessToken = token;
          // Kurangi 60 detik sebagai batas aman refresh
          _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
          return token;
        }
      } else {
        debugPrint('DOKU SNAP get token failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error DOKU SNAP get token: $e');
    }
    return null;
  }

  /// Melakukan request QRIS Dinamis ke DOKU melalui SNAP Direct API
  static Future<Map<String, dynamic>?> generateQRIS({
    required String orderId,
    required int amount,
    String itemName = 'PixyBox Payment',
  }) async {
    // 1. Dapatkan Token Akses SNAP
    final token = await _getAccessToken();
    if (token == null) {
      debugPrint('Gagal mendapatkan token SNAP DOKU, mencoba fallback ke Checkout...');
      return _generateQRISFallback(orderId: orderId, amount: amount);
    }

    const qrisPath = '/snap-adapter/b2b/v1.0/qr/qr-mpm-generate';
    final extId = '${DateTime.now().millisecondsSinceEpoch}';
    final qrisTimestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

    final qrisBody = {
      'partnerReferenceNo': orderId,
      'amount': {
        'value': amount.toDouble().toStringAsFixed(2),
        'currency': 'IDR',
      },
      'merchantId': merchantId,
      'terminalId': terminalId,
    };

    final rawQrisBody = jsonEncode(qrisBody);
    final bodyHashHex = sha256.convert(utf8.encode(rawQrisBody)).toString().toLowerCase();

    final stringToSignSymmetric = 'POST:$qrisPath:$token:$bodyHashHex:$qrisTimestamp';
    final hmacSha512 = Hmac(sha512, utf8.encode(secretKey));
    final symmetricSignature = base64Encode(hmacSha512.convert(utf8.encode(stringToSignSymmetric)).bytes);

    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl$qrisPath'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'X-PARTNER-ID': clientId,
          'X-EXTERNAL-ID': extId,
          'X-TIMESTAMP': qrisTimestamp,
          'X-SIGNATURE': symmetricSignature,
          'CHANNEL-ID': 'H2H',
        },
        body: rawQrisBody,
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final qrContent = data['qrContent'] as String?;

        if (qrContent != null && qrContent.isNotEmpty) {
          debugPrint('===================== DOKU SNAP QRIS =====================');
          debugPrint('Order ID       : $orderId');
          debugPrint('QR Content     : $qrContent');
          debugPrint('Terminal ID    : $terminalId');
          debugPrint('==========================================================');

          return {
            'order_id': orderId,
            'qr_string': qrContent,
            'qr_url': null,
            'reference_no': data['referenceNo'] ?? orderId,
          };
        } else {
          debugPrint('DOKU SNAP: qrContent kosong dalam response: ${response.body}');
        }
      } else {
        debugPrint('DOKU SNAP generate QRIS error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error generate DOKU SNAP QRIS: $e');
    }

    // Fallback jika SNAP gagal
    return _generateQRISFallback(orderId: orderId, amount: amount);
  }

  /// Mengecek status pembayaran DOKU via SNAP QRIS Query API
  static Future<String> checkPaymentStatus(String orderId) async {
    final token = await _getAccessToken();
    if (token == null) {
      return 'pending';
    }

    const queryPath = '/snap-adapter/b2b/v1.0/qr/qr-mpm-query';
    final extId = '${DateTime.now().millisecondsSinceEpoch}';
    final qrisTimestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

    final queryBody = {
      'originalPartnerReferenceNo': orderId,
      'originalReferenceNo': orderId,
      'serviceCode': '47',
      'merchantId': merchantId,
    };

    final rawBody = jsonEncode(queryBody);
    final bodyHashHex = sha256.convert(utf8.encode(rawBody)).toString().toLowerCase();

    final stringToSignSymmetric = 'POST:$queryPath:$token:$bodyHashHex:$qrisTimestamp';
    final hmacSha512 = Hmac(sha512, utf8.encode(secretKey));
    final symmetricSignature = base64Encode(hmacSha512.convert(utf8.encode(stringToSignSymmetric)).bytes);

    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl$queryPath'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'X-PARTNER-ID': clientId,
          'X-EXTERNAL-ID': extId,
          'X-TIMESTAMP': qrisTimestamp,
          'X-SIGNATURE': symmetricSignature,
          'CHANNEL-ID': 'H2H',
        },
        body: rawBody,
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestStatus = data['latestTransactionStatus']?.toString();

        // Standar SNAP QRIS BI:
        // '00' = Success / Settlement
        // '03' = Pending
        // '01' / '02' = Cancelled / Expired
        if (latestStatus == '00') {
          return 'settlement';
        } else if (latestStatus == '01' || latestStatus == '02') {
          return 'expire';
        }
        return 'pending';
      }
    } catch (e) {
      debugPrint('Doku checkPaymentStatus notice ($orderId): $e');
    }
    return 'pending';
  }

  /// Fallback ke DOKU Checkout V1 jika SNAP gagal
  static Future<Map<String, dynamic>?> _generateQRISFallback({
    required String orderId,
    required int amount,
  }) async {
    const targetPath = '/checkout/v1/payment';
    final requestId = 'REQ-${DateTime.now().millisecondsSinceEpoch}';
    final requestTimestamp = '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

    final bodyMap = {
      "order": {
        "amount": amount,
        "invoice_number": orderId,
        "currency": "IDR",
        "callback_url": "https://doku.com",
        "auto_redirect": false,
      },
      "payment": {
        "payment_due_date": 60,
        "payment_method_types": ["QRIS"],
      }
    };

    final rawBody = jsonEncode(bodyMap);
    final digestBytes = sha256.convert(utf8.encode(rawBody)).bytes;
    final digestBase64 = base64Encode(digestBytes);

    final signatureComponents =
        'Client-Id:$clientId\n'
        'Request-Id:$requestId\n'
        'Request-Timestamp:$requestTimestamp\n'
        'Request-Target:$targetPath\n'
        'Digest:$digestBase64';

    final hmac = Hmac(sha256, utf8.encode(secretKey));
    final signature = 'HMACSHA256=${base64Encode(hmac.convert(utf8.encode(signatureComponents)).bytes)}';

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
        return {
          'order_id': orderId,
          'qr_url': paymentUrl,
          'qr_string': null,
          'payment_url': paymentUrl,
        };
      }
    } catch (_) {}
    return null;
  }
}
