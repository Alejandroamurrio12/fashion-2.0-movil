import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Base SQLite del dispositivo: catalogo offline (CU59) y cola de operaciones (CU60-CU62).
/// PostgreSQL es la fuente de verdad; esto es solo la copia de trabajo y lo pendiente de enviar.
class LocalDb {
  LocalDb._(this.db);

  final Database db;

  static const _version = 1;

  /// Abre (o crea) la base. En las pruebas se pasa la fabrica de sqflite_common_ffi y
  /// `inMemoryDatabasePath`.
  static Future<LocalDb> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'fashionstore.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: _version, onCreate: (db, _) => _create(db)),
    );
    return LocalDb._(db);
  }

  static Future<void> _create(Database db) async {
    final batch = db.batch()
      ..execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
      ..execute('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, search TEXT NOT NULL, data TEXT NOT NULL)')
      ..execute('CREATE TABLE stock (branch_id INTEGER NOT NULL, product_variant_id INTEGER NOT NULL, '
          'available INTEGER NOT NULL, PRIMARY KEY (branch_id, product_variant_id))')
      ..execute('CREATE TABLE branches (id INTEGER PRIMARY KEY, name TEXT NOT NULL, city TEXT, address TEXT)')
      ..execute('CREATE TABLE customers (id INTEGER PRIMARY KEY, full_name TEXT NOT NULL, document_number TEXT)')
      ..execute('CREATE TABLE operations ('
          'client_operation_id TEXT PRIMARY KEY, local_seq INTEGER NOT NULL UNIQUE, operation_type TEXT NOT NULL, '
          'branch_id INTEGER NOT NULL, registered_at TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, '
          'attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0, user_id INTEGER NOT NULL, '
          'summary TEXT NOT NULL, provisional_code TEXT NOT NULL, result TEXT, last_error TEXT, updated_at TEXT NOT NULL)')
      ..execute('CREATE INDEX ix_operations_status ON operations (status, local_seq)');
    await batch.commit(noResult: true);
  }

  /// Borra todo lo local (al cerrar sesion o cambiar de empresa, RNF16 / RN-22).
  Future<void> clearAll() async {
    await db.transaction((tx) async {
      for (final table in ['meta', 'products', 'stock', 'branches', 'customers', 'operations']) {
        await tx.delete(table);
      }
    });
  }

  Future<void> close() => db.close();
}
