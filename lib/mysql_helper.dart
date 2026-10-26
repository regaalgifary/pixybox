import 'database_helper.dart';

/// Adapter kompatibilitas MySqlHelper -> DatabaseHelper (SQLite Embedded)
/// Memastikan semua modul existing yang masih memanggil MySqlHelper tetap berfungsi 100% tanpa perubahan.
class MySqlHelper {
  /// Uji koneksi database lokal
  static Future<bool> testConnection() => DatabaseHelper.testConnection();

  /// Login akun photobox / admin
  static Future<Map<String, dynamic>?> loginUser(
          String username, String password) =>
      DatabaseHelper.loginUser(username, password);

  /// Ambil daftar harga pengguna
  static Future<List<Map<String, dynamic>>> getPricesForUser(int idUser) =>
      DatabaseHelper.getPricesForUser(idUser);

  /// Simpan template baru
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
  }) =>
      DatabaseHelper.saveTemplate(
        idUser: idUser,
        name: name,
        imageData: imageData,
        slot1X: slot1X,
        slot1Y: slot1Y,
        slot1W: slot1W,
        slot1H: slot1H,
        slot2X: slot2X,
        slot2Y: slot2Y,
        slot2W: slot2W,
        slot2H: slot2H,
        slot3X: slot3X,
        slot3Y: slot3Y,
        slot3W: slot3W,
        slot3H: slot3H,
        assignedBoothIds: assignedBoothIds,
      );

  /// Ambil template sesuai role dan user
  static Future<List<Map<String, dynamic>>> getTemplatesForUser(
          int idUser, String role) =>
      DatabaseHelper.getTemplatesForUser(idUser, role);

  /// Ambil daftar akun booth
  static Future<List<Map<String, dynamic>>> getBoothUsers() =>
      DatabaseHelper.getBoothUsers();

  /// Ambil daftar penugasan booth untuk template
  static Future<List<int>> getTemplateAssignments(int idTemplate) =>
      DatabaseHelper.getTemplateAssignments(idTemplate);

  /// Hapus template
  static Future<void> deleteTemplate(int idTemplate) =>
      DatabaseHelper.deleteTemplate(idTemplate);

  /// Catat riwayat sesi awal
  static Future<void> createSessionHistory({
    required String orderId,
    required int idUser,
    int? idTemplate,
    String? templateName,
    required int printCount,
    required double totalPrice,
    String paymentType = 'qris',
  }) =>
      DatabaseHelper.createSessionHistory(
        orderId: orderId,
        idUser: idUser,
        idTemplate: idTemplate,
        templateName: templateName,
        printCount: printCount,
        totalPrice: totalPrice,
        paymentType: paymentType,
      );

  /// Update status pembayaran dan sesi
  static Future<void> updateSessionStatus({
    required String orderId,
    required String paymentStatus,
    String? sessionStatus,
    int? idTemplate,
    String? templateName,
  }) =>
      DatabaseHelper.updateSessionStatus(
        orderId: orderId,
        paymentStatus: paymentStatus,
        sessionStatus: sessionStatus,
        idTemplate: idTemplate,
        templateName: templateName,
      );

  /// Ambil riwayat sesi photobox
  static Future<List<Map<String, dynamic>>> getSessionHistories(
          {int? idUser, int limit = 50}) =>
      DatabaseHelper.getSessionHistories(idUser: idUser, limit: limit);

  /// Eksekusi query kustom (bila ada)
  static Future<List<Map<String, dynamic>>> query(String sql,
          [List<Object?>? args]) =>
      DatabaseHelper.query(sql, args);

  /// Eksekusi update/insert kustom (bila ada)
  static Future<int> execute(String sql, [List<Object?>? args]) =>
      DatabaseHelper.execute(sql, args);
}
