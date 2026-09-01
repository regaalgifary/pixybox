import 'package:mysql1/mysql1.dart';

class MySqlHelper {
  // Konfigurasi koneksi MySQL local (phpMyAdmin)
  static const String _host = '127.0.0.1'; // localhost
  static const int _port = 3306;
  static const String _user = 'root';
  static const String? _password = null; // Set null jika tidak ada password pada XAMPP
  static const String _db = 'pixybox';

  /// Mendapatkan konfigurasi koneksi
  static ConnectionSettings get _settings {
    return ConnectionSettings(
      host: _host,
      port: _port,
      user: _user,
      password: _password,
      db: _db,
    );
  }

  /// Fungsi untuk menguji koneksi ke database `pixybox` dan melakukan migrasi
  static Future<bool> testConnection() async {
    MySqlConnection? conn;
    try {
      // Mencoba membuka koneksi
      conn = await MySqlConnection.connect(_settings);
      
      // Jika berhasil, lakukan query sederhana untuk pengetesan
      await conn.query('SELECT 1');

      // Auto-create tabel templates jika belum ada
      await conn.query('''
        CREATE TABLE IF NOT EXISTS `templates` (
          `id_template` INT AUTO_INCREMENT PRIMARY KEY,
          `id_user` INT NOT NULL,
          `name` VARCHAR(100) NOT NULL,
          `image_data` LONGBLOB NOT NULL,
          `slot1_x` DOUBLE NOT NULL DEFAULT 0.1,
          `slot1_y` DOUBLE NOT NULL DEFAULT 0.1,
          `slot1_w` DOUBLE NOT NULL DEFAULT 0.8,
          `slot1_h` DOUBLE NOT NULL DEFAULT 0.25,
          `slot2_x` DOUBLE NOT NULL DEFAULT 0.1,
          `slot2_y` DOUBLE NOT NULL DEFAULT 0.4,
          `slot2_w` DOUBLE NOT NULL DEFAULT 0.8,
          `slot2_h` DOUBLE NOT NULL DEFAULT 0.25,
          `slot3_x` DOUBLE NOT NULL DEFAULT 0.1,
          `slot3_y` DOUBLE NOT NULL DEFAULT 0.7,
          `slot3_w` DOUBLE NOT NULL DEFAULT 0.8,
          `slot3_h` DOUBLE NOT NULL DEFAULT 0.25,
          `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      ''');

      // Auto-create tabel template_assignments jika belum ada
      await conn.query('''
        CREATE TABLE IF NOT EXISTS `template_assignments` (
          `id_assignment` INT AUTO_INCREMENT PRIMARY KEY,
          `id_template` INT NOT NULL,
          `id_user` INT NOT NULL,
          FOREIGN KEY (`id_template`) REFERENCES `templates`(`id_template`) ON DELETE CASCADE,
          FOREIGN KEY (`id_user`) REFERENCES `users`(`id_user`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      ''');
      
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('Gagal terhubung ke MySQL: $e');
      return false;
    } finally {
      // Selalu pastikan koneksi ditutup kembali
      if (conn != null) {
        await conn.close();
      }
    }
  }

  /// Fungsi login untuk memverifikasi akun photobox
  static Future<Map<String, dynamic>?> loginUser(String username, String password) async {
    MySqlConnection? conn;
    try {
      conn = await MySqlConnection.connect(_settings);
      
      // Lakukan pencarian user berdasarkan username dan password
      final results = await conn.query(
        'SELECT id_user, username, role, alamat_photobox FROM users WHERE username = ? AND password = ? LIMIT 1',
        [username, password],
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
      // ignore: avoid_print
      print('Error pada loginUser: $e');
      return null;
    } finally {
      if (conn != null) {
        await conn.close();
      }
    }
  }

  /// Mengambil daftar harga untuk user/photobox tertentu
  static Future<List<Map<String, dynamic>>> getPricesForUser(int idUser) async {
    MySqlConnection? conn;
    try {
      conn = await MySqlConnection.connect(_settings);
      
      final results = await conn.query(
        'SELECT print_count, price FROM prices WHERE id_user = ? ORDER BY print_count ASC',
        [idUser],
      );

      List<Map<String, dynamic>> prices = [];
      for (var row in results) {
        prices.add({
          'print_count': row['print_count'] as int,
          'price': double.parse(row['price'].toString()),
        });
      }
      return prices;
    } catch (e) {
      // ignore: avoid_print
      print('Error pada getPricesForUser: $e');
      return [];
    } finally {
      if (conn != null) {
        await conn.close();
      }
    }
  }

  /// Fungsi umum untuk menjalankan query (SELECT)
  static Future<Results> query(String sql, [List<Object?>? placeholderValues]) async {
    final conn = await MySqlConnection.connect(_settings);
    try {
      return await conn.query(sql, placeholderValues);
    } finally {
      await conn.close();
    }
  }

  /// Fungsi umum untuk menjalankan eksekusi data (INSERT, UPDATE, DELETE)
  static Future<Results> execute(String sql, [List<Object?>? placeholderValues]) async {
    final conn = await MySqlConnection.connect(_settings);
    try {
      return await conn.query(sql, placeholderValues);
    } finally {
      await conn.close();
    }
  }

  /// Menyimpan template baru ke database beserta mapping booth
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
    final conn = await MySqlConnection.connect(_settings);
    try {
      final result = await conn.query(
        '''
        INSERT INTO templates (
          id_user, name, image_data,
          slot1_x, slot1_y, slot1_w, slot1_h,
          slot2_x, slot2_y, slot2_w, slot2_h,
          slot3_x, slot3_y, slot3_w, slot3_h
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          idUser,
          name,
          Blob.fromBytes(imageData),
          slot1X,
          slot1Y,
          slot1W,
          slot1H,
          slot2X,
          slot2Y,
          slot2W,
          slot2H,
          slot3X,
          slot3Y,
          slot3W,
          slot3H,
        ],
      );
      final templateId = result.insertId;
      if (templateId != null) {
        for (var boothId in assignedBoothIds) {
          await conn.query(
            'INSERT INTO template_assignments (id_template, id_user) VALUES (?, ?)',
            [templateId, boothId],
          );
        }
      }
    } finally {
      await conn.close();
    }
  }

  /// Mengambil semua template berdasarkan role dan user
  static Future<List<Map<String, dynamic>>> getTemplatesForUser(int idUser, String role) async {
    Results results;
    if (role == 'admin') {
      results = await query(
        'SELECT id_template, id_user, name, image_data, slot1_x, slot1_y, slot1_w, slot1_h, slot2_x, slot2_y, slot2_w, slot2_h, slot3_x, slot3_y, slot3_w, slot3_h FROM templates ORDER BY id_template DESC'
      );
    } else {
      results = await query(
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
      final blob = row['image_data'] as Blob;
      list.add({
        'id_template': row['id_template'] as int,
        'id_user': row['id_user'] as int,
        'name': row['name'] as String,
        'image_data': blob.toBytes(),
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

  /// Mengambil semua akun user dengan role booth
  static Future<List<Map<String, dynamic>>> getBoothUsers() async {
    final results = await query(
      "SELECT id_user, username, alamat_photobox FROM users WHERE role = 'booth' ORDER BY username ASC"
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
  }

  /// Mengambil daftar booth user ID yang di-assign ke suatu template
  static Future<List<int>> getTemplateAssignments(int idTemplate) async {
    final results = await query(
      'SELECT id_user FROM template_assignments WHERE id_template = ?',
      [idTemplate],
    );
    List<int> list = [];
    for (var row in results) {
      list.add(row['id_user'] as int);
    }
    return list;
  }

  /// Menghapus template berdasarkan ID
  static Future<void> deleteTemplate(int idTemplate) async {
    await execute('DELETE FROM templates WHERE id_template = ?', [idTemplate]);
  }
}
