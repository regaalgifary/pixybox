import 'dart:convert';
import 'package:http/http.dart' as http;

class MidtransService {
  // Ganti dengan SERVER KEY Sandbox / Production Anda (didapat dari dashboard Midtrans -> Settings -> Access Keys)
  // Format Sandbox: SB-Mid-server-... / Production: Mid-server-...
  static const String _serverKey = 'YOUR_MIDTRANS_SERVER_KEY'; 
  static const String _baseUrl = 'https://api.sandbox.midtrans.com/v2';

  /// Melakukan request QRIS ke Midtrans
  static Future<Map<String, dynamic>?> generateQRIS({
    required String orderId,
    required int amount,
    String itemName = 'PixyBox Payment',
  }) async {
    // Gunakan Server Key untuk otorisasi Basic Auth
    final String basicAuth = 'Basic ${base64Encode(utf8.encode('$_serverKey:'))}';
    
    try {
      final response = await http.post(
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
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final actions = data['actions'] as List;
        final qrAction = actions.firstWhere((action) => action['name'] == 'generate-qr-code');
        
        return {
          'order_id': orderId,
          'qr_url': qrAction['url'], // URL Gambar QRIS
        };
      } else {
        print('Gagal generate QRIS: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('Error generateQRIS: $e');
    }
    return null;
  }

  /// Mengecek status pembayaran (Polling)
  static Future<String> checkPaymentStatus(String orderId) async {
    final String basicAuth = 'Basic ${base64Encode(utf8.encode('$_serverKey:'))}';
    
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/$orderId/status'),
        headers: {
          'Accept': 'application/json',
          'Authorization': basicAuth,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Status yang sukses biasanya 'settlement' atau 'capture'
        return data['transaction_status'] ?? 'pending';
      }
    } catch (e) {
      print('Error checkPaymentStatus: $e');
    }
    return 'pending';
  }
}
