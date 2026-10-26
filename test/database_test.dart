import 'package:flutter_test/flutter_test.dart';
import 'package:pixybox/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('DatabaseHelper SQLite Unit Tests', () {
    test('Database can be initialized and seeds default data', () async {
      await DatabaseHelper.initDatabase();
      final isConnected = await DatabaseHelper.testConnection();
      expect(isConnected, isTrue);

      // Verify admin login
      final adminUser = await DatabaseHelper.loginUser('admin_pixy', 'admin123');
      expect(adminUser, isNotNull);
      expect(adminUser?['role'], equals('admin'));

      // Verify booth login
      final boothUser = await DatabaseHelper.loginUser('photobox_01', 'password123');
      expect(boothUser, isNotNull);
      expect(boothUser?['role'], equals('booth'));

      // Verify invalid credentials
      final wrongUser = await DatabaseHelper.loginUser('admin_pixy', 'wrong_pass');
      expect(wrongUser, isNull);

      // Verify prices
      final prices = await DatabaseHelper.getPricesForUser(1);
      expect(prices.isNotEmpty, isTrue);
      expect(prices.first['price'], equals(1000.0));

      // Verify default template
      final templates = await DatabaseHelper.getTemplatesForUser(1, 'booth');
      expect(templates.isNotEmpty, isTrue);
      expect(templates.first['name'], contains('Pixybox'));
    });
  });
}
