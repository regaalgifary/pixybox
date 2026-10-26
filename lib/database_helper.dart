import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'price_config.dart';

/// Database Helper menggunakan SQLite Embedded (sqflite_common_ffi)
/// Menyediakan penyimpanan lokal mandiri tanpa perlu server XAMPP/MySQL terpisah.
class DatabaseHelper {
  static Database? _database;
  static bool _isFfiInitialized = false;

  /// Inisialisasi FFI untuk desktop (Windows, Linux, macOS)
  static void initializeFfi() {
    if (_isFfiInitialized) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _isFfiInitialized = true;
  }

  /// Lokasi file database SQLite lokal
  static Future<String> getDbPath() async {
    try {
      final docDir = await getApplicationSupportDirectory();
      await docDir.create(recursive: true);
      return p.join(docDir.path, 'pixybox.db');
    } catch (e) {
      debugPrint('Fallback database path ke direktori aplikasi: $e');
      return p.join(Directory.current.path, 'pixybox.db');
    }
  }

  /// Instance database singleton
  static Future<Database> get database async {
    if (_database != null) return _database!;
    initializeFfi();
    _database = await _initDatabase();
    return _database!;
  }

  /// Membuka dan menginisialisasi tabel-tabel SQLite
  static Future<Database> _initDatabase() async {
    final dbPath = await getDbPath();
    debugPrint('Database SQLite path: $dbPath');

    final db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await _createTables(db);
        await _seedInitialData(db);
      },
      onOpen: (db) async {
        await _createTables(db);
        await _seedInitialData(db);
      },
    );

    return db;
  }

  /// Inisialisasi awal database saat aplikasi start
  static Future<void> initDatabase() async {
    try {
      initializeFfi();
      await database;
      debugPrint('Database lokal SQLite Pixybox berhasil diinisialisasi.');
    } catch (e) {
      debugPrint('Error saat inisialisasi database SQLite: $e');
    }
  }

  /// Membuat struktur tabel jika belum ada
  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id_user INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        password TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'booth',
        alamat_photobox TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS prices (
        id_price INTEGER PRIMARY KEY AUTOINCREMENT,
        id_user INTEGER NOT NULL,
        print_count INTEGER NOT NULL,
        price REAL NOT NULL,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (id_user) REFERENCES users (id_user) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS templates (
        id_template INTEGER PRIMARY KEY AUTOINCREMENT,
        id_user INTEGER NOT NULL,
        name TEXT NOT NULL,
        image_data BLOB NOT NULL,
        slot1_x REAL NOT NULL DEFAULT 0.075,
        slot1_y REAL NOT NULL DEFAULT 0.055,
        slot1_w REAL NOT NULL DEFAULT 0.85,
        slot1_h REAL NOT NULL DEFAULT 0.255,
        slot2_x REAL NOT NULL DEFAULT 0.075,
        slot2_y REAL NOT NULL DEFAULT 0.333,
        slot2_w REAL NOT NULL DEFAULT 0.85,
        slot2_h REAL NOT NULL DEFAULT 0.255,
        slot3_x REAL NOT NULL DEFAULT 0.075,
        slot3_y REAL NOT NULL DEFAULT 0.611,
        slot3_w REAL NOT NULL DEFAULT 0.85,
        slot3_h REAL NOT NULL DEFAULT 0.255,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (id_user) REFERENCES users (id_user) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS template_assignments (
        id_assignment INTEGER PRIMARY KEY AUTOINCREMENT,
        id_template INTEGER NOT NULL,
        id_user INTEGER NOT NULL,
        FOREIGN KEY (id_template) REFERENCES templates (id_template) ON DELETE CASCADE,
        FOREIGN KEY (id_user) REFERENCES users (id_user) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_history (
        id_session INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT NOT NULL UNIQUE,
        id_user INTEGER NOT NULL,
        id_template INTEGER NULL,
        template_name TEXT NULL,
        print_count INTEGER NOT NULL DEFAULT 1,
        total_price REAL NOT NULL DEFAULT 0.00,
        payment_type TEXT NOT NULL DEFAULT 'qris',
        payment_status TEXT NOT NULL DEFAULT 'pending',
        session_status TEXT NOT NULL DEFAULT 'started',
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (id_user) REFERENCES users (id_user) ON DELETE CASCADE,
        FOREIGN KEY (id_template) REFERENCES templates (id_template) ON DELETE SET NULL
      );
    ''');

    // Index untuk optimasi pencarian
    await db.execute('CREATE INDEX IF NOT EXISTS idx_order_id ON session_history (order_id);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_user_date ON session_history (id_user, created_at);');
  }

  /// Membuat template default otomatis agar software langsung dapat digunakan
  static Uint8List _generateDefaultTemplatePng() {
    try {
      final image = img.Image(width: 1200, height: 1800, numChannels: 4);
      // Background transparan
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));

      // Garis border luar aesthetic
      img.drawRect(
        image,
        x1: 40,
        y1: 40,
        x2: 1160,
        y2: 1760,
        color: img.ColorRgba8(240, 240, 240, 240),
        thickness: 6,
      );

      // Frame Slot 1
      img.drawRect(
        image,
        x1: 90,
        y1: 100,
        x2: 1110,
        y2: 560,
        color: img.ColorRgba8(255, 255, 255, 180),
        thickness: 3,
      );

      // Frame Slot 2
      img.drawRect(
        image,
        x1: 90,
        y1: 600,
        x2: 1110,
        y2: 1060,
        color: img.ColorRgba8(255, 255, 255, 180),
        thickness: 3,
      );

      // Frame Slot 3
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

  static int? _firstIntValue(List<Map<String, dynamic>> list) {
    if (list.isNotEmpty && list.first.isNotEmpty) {
      final val = list.first.values.first;
      if (val is int) return val;
      if (val is num) return val.toInt();
      if (val != null) return int.tryParse(val.toString());
    }
    return null;
  }

  /// Mengisi data awal (Mock Akun Photobox, Harga, dan Template Default)
  static Future<void> _seedInitialData(Database db) async {
    // Cek apakah tabel users masih kosong
    final userCount = _firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM users'),
        ) ??
        0;

    if (userCount == 0) {
      debugPrint('Seeding data awal pengguna Pixybox...');
      await db.insert('users', {
        'id_user': 1,
        'username': 'photobox_01',
        'password': 'password123',
        'role': 'booth',
        'alamat_photobox': 'Mall Kelapa Gading, Jakarta',
      });
      await db.insert('users', {
        'id_user': 2,
        'username': 'photobox_02',
        'password': 'password123',
        'role': 'booth',
        'alamat_photobox': 'Tunjungan Plaza, Surabaya',
      });
      await db.insert('users', {
        'id_user': 3,
        'username': 'admin_pixy',
        'password': 'admin123',
        'role': 'admin',
        'alamat_photobox': 'Head Office Jakarta',
      });

      // Seeding daftar harga
      await db.insert('prices', {'id_user': 1, 'print_count': 1, 'price': 25000.0});
      await db.insert('prices', {'id_user': 1, 'print_count': 2, 'price': 35000.0});
      await db.insert('prices', {'id_user': 2, 'print_count': 1, 'price': 30000.0});
      await db.insert('prices', {'id_user': 2, 'print_count': 2, 'price': 45000.0});
      await db.insert('prices', {'id_user': 3, 'print_count': 1, 'price': 25000.0});
      await db.insert('prices', {'id_user': 3, 'print_count': 2, 'price': 35000.0});
    }

    // Cek apakah templates kosong
    final templateCount = _firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM templates'),
        ) ??
        0;

    if (templateCount == 0) {
      debugPrint('Seeding template default Pixybox...');
      final pngBytes = _generateDefaultTemplatePng();
      if (pngBytes.isNotEmpty) {
        final idTemplate = await db.insert('templates', {
          'id_user': 3,
          'name': 'Classic 3-Strip Pixybox',
          'image_data': pngBytes,
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
        });

        // Assign template ke semua booth (1, 2, 3)
        for (var boothId in [1, 2, 3]) {
          await db.insert('template_assignments', {
            'id_template': idTemplate,
            'id_user': boothId,
          });
        }
      }
    }
  }

  /// Fungsi uji koneksi database
  static Future<bool> testConnection() async {
    try {
      final db = await database;
      await db.rawQuery('SELECT 1');
      return true;
    } catch (e) {
      debugPrint('Gagal koneksi SQLite: $e');
      return false;
    }
  }

  /// Login dan validasi akun photobox / admin
  static Future<Map<String, dynamic>?> loginUser(
      String username, String password) async {
    try {
      final db = await database;
      final results = await db.query(
        'users',
        columns: ['id_user', 'username', 'role', 'alamat_photobox'],
        where: 'username = ? AND password = ?',
        whereArgs: [username, password],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final row = results.first;
        return {
          'id_user': row['id_user'] as int,
          'username': row['username'] as String,
          'role': row['role'] as String,
          'alamat_photobox': row['alamat_photobox']?.toString(),
        };
      }
      return null;
    } catch (e) {
      debugPrint('Error pada loginUser: $e');
      return null;
    }
  }

  /// Mengambil daftar harga untuk photobox tertentu (memprioritaskan prices.json)
  static Future<List<Map<String, dynamic>>> getPricesForUser(int idUser) async {
    try {
      // 1. Coba ambil dari file konfigurasi JSON (prices.json)
      final jsonPrices = await PriceConfig.getPricesForUser(idUser);
      if (jsonPrices.isNotEmpty) {
        return jsonPrices;
      }
    } catch (e) {
      debugPrint('Fallback membaca harga dari database SQLite: $e');
    }

    try {
      final db = await database;
      final results = await db.query(
        'prices',
        columns: ['print_count', 'price'],
        where: 'id_user = ?',
        whereArgs: [idUser],
        orderBy: 'print_count ASC',
      );

      List<Map<String, dynamic>> prices = [];
      for (var row in results) {
        prices.add({
          'print_count': row['print_count'] as int,
          'price': double.parse(row['price'].toString()),
          'label': '${row['print_count']}x Cetak',
        });
      }

      if (prices.isNotEmpty) {
        return prices;
      }
    } catch (e) {
      debugPrint('Error pada getPricesForUser: $e');
    }

    return [
      {'print_count': 1, 'price': 25000.0, 'label': '1x Cetak'},
      {'print_count': 2, 'price': 35000.0, 'label': '2x Cetak'},
    ];
  }

  /// Menyimpan template baru beserta penugasan booth
  static Future<void> saveTemplate({
    required int idUser,
    required String name,
    required List<int> imageData,
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
    required List<int> assignedBoothIds,
  }) async {
    final db = await database;
    final templateId = await db.insert('templates', {
      'id_user': idUser,
      'name': name,
      'image_data': Uint8List.fromList(imageData),
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
    });

    for (var boothId in assignedBoothIds) {
      await db.insert('template_assignments', {
        'id_template': templateId,
        'id_user': boothId,
      });
    }
  }

  /// Mengambil template sesuai role dan user
  static Future<List<Map<String, dynamic>>> getTemplatesForUser(
      int idUser, String role) async {
    final db = await database;
    List<Map<String, dynamic>> results;

    if (role == 'admin') {
      results = await db.rawQuery(
        'SELECT id_template, id_user, name, image_data, slot1_x, slot1_y, slot1_w, slot1_h, slot2_x, slot2_y, slot2_w, slot2_h, slot3_x, slot3_y, slot3_w, slot3_h FROM templates ORDER BY id_template DESC',
      );
    } else {
      results = await db.rawQuery(
        '''
        SELECT t.id_template, t.id_user, t.name, t.image_data, 
               t.slot1_x, t.slot1_y, t.slot1_w, t.slot1_h, 
               t.slot2_x, t.slot2_y, t.slot2_w, t.slot2_h, 
               t.slot3_x, t.slot3_y, t.slot3_w, t.slot3_h 
        FROM templates t
        INNER JOIN template_assignments ta ON t.id_template = ta.id_template
        WHERE ta.id_user = ?
        ORDER BY t.id_template DESC
        ''',
        [idUser],
      );
    }

    List<Map<String, dynamic>> list = [];
    for (var row in results) {
      final imgBytes = row['image_data'];
      Uint8List bytes;
      if (imgBytes is Uint8List) {
        bytes = imgBytes;
      } else if (imgBytes is List<int>) {
        bytes = Uint8List.fromList(imgBytes);
      } else {
        bytes = Uint8List(0);
      }

      list.add({
        'id_template': row['id_template'] as int,
        'id_user': row['id_user'] as int,
        'name': row['name'] as String,
        'image_data': bytes,
        'slot1_x': double.parse(row['slot1_x'].toString()),
        'slot1_y': double.parse(row['slot1_y'].toString()),
        'slot1_w': double.parse(row['slot1_w'].toString()),
        'slot1_h': double.parse(row['slot1_h'].toString()),
        'slot2_x': double.parse(row['slot2_x'].toString()),
        'slot2_y': double.parse(row['slot2_y'].toString()),
        'slot2_w': double.parse(row['slot2_w'].toString()),
        'slot2_h': double.parse(row['slot2_h'].toString()),
        'slot3_x': double.parse(row['slot3_x'].toString()),
        'slot3_y': double.parse(row['slot3_y'].toString()),
        'slot3_w': double.parse(row['slot3_w'].toString()),
        'slot3_h': double.parse(row['slot3_h'].toString()),
      });
    }
    return list;
  }

  /// Mengambil semua akun user role booth
  static Future<List<Map<String, dynamic>>> getBoothUsers() async {
    try {
      final db = await database;
      final results = await db.query(
        'users',
        columns: ['id_user', 'username', 'alamat_photobox'],
        where: 'role = ?',
        whereArgs: ['booth'],
        orderBy: 'username ASC',
      );
      List<Map<String, dynamic>> list = [];
      for (var row in results) {
        list.add({
          'id_user': row['id_user'] as int,
          'username': row['username'] as String,
          'alamat_photobox': row['alamat_photobox']?.toString(),
        });
      }
      return list;
    } catch (e) {
      debugPrint('Error getBoothUsers: $e');
      return [];
    }
  }

  /// Mengambil daftar booth user yang di-assign ke template
  static Future<List<int>> getTemplateAssignments(int idTemplate) async {
    try {
      final db = await database;
      final results = await db.query(
        'template_assignments',
        columns: ['id_user'],
        where: 'id_template = ?',
        whereArgs: [idTemplate],
      );
      return results.map((r) => r['id_user'] as int).toList();
    } catch (e) {
      debugPrint('Error getTemplateAssignments: $e');
      return [];
    }
  }

  /// Menghapus template
  static Future<void> deleteTemplate(int idTemplate) async {
    final db = await database;
    await db.delete('template_assignments',
        where: 'id_template = ?', whereArgs: [idTemplate]);
    await db.delete('templates',
        where: 'id_template = ?', whereArgs: [idTemplate]);
  }

  /// Mencatat riwayat sesi saat pembayaran diinisiasi
  static Future<void> createSessionHistory({
    required String orderId,
    required int idUser,
    int? idTemplate,
    String? templateName,
    required int printCount,
    required double totalPrice,
    String paymentType = 'qris',
  }) async {
    try {
      final db = await database;
      await db.insert(
        'session_history',
        {
          'order_id': orderId,
          'id_user': idUser,
          'id_template': idTemplate,
          'template_name': templateName,
          'print_count': printCount,
          'total_price': totalPrice,
          'payment_type': paymentType,
          'payment_status': 'pending',
          'session_status': 'started',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('Error pada createSessionHistory: $e');
    }
  }

  /// Update status pembayaran dan alur sesi
  static Future<void> updateSessionStatus({
    required String orderId,
    required String paymentStatus,
    String? sessionStatus,
    int? idTemplate,
    String? templateName,
  }) async {
    try {
      final db = await database;
      final Map<String, dynamic> values = {
        'payment_status': paymentStatus,
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (sessionStatus != null) values['session_status'] = sessionStatus;
      if (idTemplate != null) values['id_template'] = idTemplate;
      if (templateName != null) values['template_name'] = templateName;

      await db.update(
        'session_history',
        values,
        where: 'order_id = ?',
        whereArgs: [orderId],
      );
    } catch (e) {
      debugPrint('Error pada updateSessionStatus: $e');
    }
  }

  /// Mengambil daftar riwayat sesi
  static Future<List<Map<String, dynamic>>> getSessionHistories(
      {int? idUser, int limit = 50}) async {
    try {
      final db = await database;
      List<Map<String, dynamic>> results;
      if (idUser != null) {
        results = await db.rawQuery(
          '''
          SELECT sh.*, u.username, u.alamat_photobox 
          FROM session_history sh
          JOIN users u ON sh.id_user = u.id_user
          WHERE sh.id_user = ?
          ORDER BY sh.id_session DESC
          LIMIT ?
          ''',
          [idUser, limit],
        );
      } else {
        results = await db.rawQuery(
          '''
          SELECT sh.*, u.username, u.alamat_photobox 
          FROM session_history sh
          JOIN users u ON sh.id_user = u.id_user
          ORDER BY sh.id_session DESC
          LIMIT ?
          ''',
          [limit],
        );
      }

      List<Map<String, dynamic>> list = [];
      for (var row in results) {
        list.add({
          'id_session': row['id_session'] as int,
          'order_id': row['order_id'] as String,
          'id_user': row['id_user'] as int,
          'username': row['username'] as String?,
          'alamat_photobox': row['alamat_photobox']?.toString(),
          'id_template': row['id_template'] as int?,
          'template_name': row['template_name'] as String?,
          'print_count': row['print_count'] as int,
          'total_price': double.tryParse(row['total_price'].toString()) ?? 0.0,
          'payment_type': row['payment_type'] as String,
          'payment_status': row['payment_status'] as String,
          'session_status': row['session_status'] as String,
          'created_at': row['created_at'].toString(),
          'updated_at': row['updated_at'].toString(),
        });
      }
      return list;
    } catch (e) {
      debugPrint('Error pada getSessionHistories: $e');
      return [];
    }
  }

  /// Helper untuk raw query
  static Future<List<Map<String, dynamic>>> query(String sql,
      [List<Object?>? args]) async {
    final db = await database;
    return await db.rawQuery(sql, args);
  }

  /// Helper untuk raw execute / update / insert
  static Future<int> execute(String sql, [List<Object?>? args]) async {
    final db = await database;
    return await db.rawInsert(sql, args);
  }
}
