import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

enum PaymentGateway { midtrans, doku }

class PaymentConfig {
  static const String _configFile = 'payment_config.json';
  
  // Default Gateway yang aktif
  static PaymentGateway activeGateway = PaymentGateway.doku;

  /// Memuat preferensi gateway dari file konfigurasi lokal
  static Future<void> loadConfig() async {
    try {
      final file = File(_configFile);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        final gatewayStr = (data['active_gateway'] as String?)?.toLowerCase();
        if (gatewayStr == 'midtrans') {
          activeGateway = PaymentGateway.midtrans;
        } else {
          activeGateway = PaymentGateway.doku;
        }
      } else {
        // Simpan default jika file belum ada
        await saveConfig(activeGateway);
      }
    } catch (e) {
      debugPrint('Error loading payment config: $e');
    }
  }

  /// Menyimpan preferensi gateway aktif ke file lokal
  static Future<void> saveConfig(PaymentGateway gateway) async {
    try {
      activeGateway = gateway;
      final file = File(_configFile);
      final data = {
        'active_gateway': gateway == PaymentGateway.midtrans ? 'midtrans' : 'doku',
        'updated_at': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } catch (e) {
      debugPrint('Error saving payment config: $e');
    }
  }

  static String get activeGatewayName =>
      activeGateway == PaymentGateway.midtrans ? 'Midtrans' : 'DOKU';
}
