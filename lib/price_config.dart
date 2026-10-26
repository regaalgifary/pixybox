import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Layanan konfigurasi harga berbasis JSON (prices.json)
/// Memudahkan pengaturan harga photobox tanpa harus mengubah database SQLite / MySQL.
class PriceConfig {
  static const String fileName = 'prices.json';

  /// Default daftar harga jika file prices.json belum ada
  static final Map<String, dynamic> defaultData = {
    "prices": [
      {
        "print_count": 1,
        "price": 1000,
        "label": "1x Cetak"
      },
      {
        "print_count": 2,
        "price": 2000,
        "label": "2x Cetak"
      }
    ],
    "booth_prices": {}
  };

  /// Mencari lokasi file prices.json:
  /// 1. Di direktori yang sama dengan executable (.exe)
  /// 2. Di Current Working Directory (root proyek saat debug)
  static File getConfigFile() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final exeFile = File(p.join(exeDir, fileName));
      if (exeFile.existsSync()) return exeFile;
    } catch (_) {}

    try {
      final cwdFile = File(fileName);
      if (cwdFile.existsSync()) return cwdFile;
    } catch (_) {}

    // Jika belum ada, tentukan lokasi terbaik untuk dibuat:
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      // Jika folder exe valid dan bukan di debug mode bawaan platform runner
      if (Directory(exeDir).existsSync() && !kDebugMode) {
        return File(p.join(exeDir, fileName));
      }
    } catch (_) {}

    return File(fileName);
  }

  /// Lokasi absolut file prices.json yang sedang aktif
  static String get configFilePath => getConfigFile().path;

  /// Memastikan file prices.json ada. Jika belum ada, buat dengan data default.
  static Future<void> ensureInitialized() async {
    try {
      final file = getConfigFile();
      if (!await file.exists()) {
        final encoder = const JsonEncoder.withIndent('  ');
        await file.writeAsString(encoder.convert(defaultData));
        debugPrint('File prices.json berhasil dibuat di: ${file.path}');
      }
    } catch (e) {
      debugPrint('Error saat inisialisasi prices.json: $e');
    }
  }

  /// Mengambil daftar harga untuk booth / user tertentu
  static Future<List<Map<String, dynamic>>> getPricesForUser(int idUser) async {
    try {
      final file = getConfigFile();
      if (!await file.exists()) {
        await ensureInitialized();
      }

      if (await file.exists()) {
        final content = await file.readAsString();
        final dynamic decoded = jsonDecode(content);

        // Kasus 1: Format map dengan `booth_prices` dan `prices`
        if (decoded is Map<String, dynamic>) {
          // Cek apakah ada konfigurasi khusus untuk booth idUser
          final boothPrices = decoded['booth_prices'];
          if (boothPrices is Map<String, dynamic>) {
            final userKey = idUser.toString();
            if (boothPrices.containsKey(userKey) && boothPrices[userKey] is List) {
              return _parsePriceList(boothPrices[userKey] as List);
            }
          }

          // Cek key umum `prices`
          if (decoded.containsKey('prices') && decoded['prices'] is List) {
            return _parsePriceList(decoded['prices'] as List);
          }

          // Format simpel key-value: {"1": 25000, "2": 35000}
          List<Map<String, dynamic>> simpleList = [];
          decoded.forEach((key, val) {
            final count = int.tryParse(key);
            final priceNum = val is num ? val.toDouble() : double.tryParse(val.toString());
            if (count != null && priceNum != null) {
              simpleList.add({
                'print_count': count,
                'price': priceNum,
                'label': '${count}x Cetak',
              });
            }
          });
          if (simpleList.isNotEmpty) {
            simpleList.sort((a, b) => (a['print_count'] as int).compareTo(b['print_count'] as int));
            return simpleList;
          }
        }

        // Kasus 2: Format langsung list: [{"print_count": 1, "price": 25000}, ...]
        if (decoded is List) {
          return _parsePriceList(decoded);
        }
      }
    } catch (e) {
      debugPrint('Error membaca prices.json: $e');
    }

    // Fallback default
    return [
      {'print_count': 1, 'price': 25000.0, 'label': '1x Cetak'},
      {'print_count': 2, 'price': 35000.0, 'label': '2x Cetak'},
    ];
  }

  /// Helper untuk mem-parsing List JSON menjadi List Map harga terstandarisasi
  static List<Map<String, dynamic>> _parsePriceList(List rawList) {
    List<Map<String, dynamic>> result = [];
    for (var item in rawList) {
      if (item is Map) {
        final count = item['print_count'] is int
            ? item['print_count'] as int
            : int.tryParse(item['print_count']?.toString() ?? '1') ?? 1;

        final price = item['price'] is num
            ? (item['price'] as num).toDouble()
            : double.tryParse(item['price']?.toString() ?? '0.0') ?? 0.0;

        final label = item['label']?.toString() ?? '${count}x Cetak';

        result.add({
          'print_count': count,
          'price': price,
          'label': label,
        });
      }
    }

    result.sort((a, b) => (a['print_count'] as int).compareTo(b['print_count'] as int));
    return result;
  }
}
