import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../branch/branch_service.dart';
import '../core/api_client.dart';
import 'local_db.dart';

class CatalogInfo {
  CatalogInfo({required this.generatedAt, required this.maxAgeHours, required this.currency, required this.products});

  final DateTime generatedAt;
  final int maxAgeHours;
  final String currency;
  final int products;

  factory CatalogInfo.fromJson(Map<String, dynamic> j) => CatalogInfo(
        generatedAt: DateTime.parse(j['generated_at'] as String),
        maxAgeHours: j['max_age_hours'] as int,
        currency: j['currency'] as String,
        products: j['products'] as int,
      );

  Map<String, dynamic> toJson() => {
        'generated_at': generatedAt.toIso8601String(),
        'max_age_hours': maxAgeHours,
        'currency': currency,
        'products': products,
      };
}

/// Prenda del catalogo local: producto + variante, con su precio vigente al descargar.
class LocalVariant {
  LocalVariant({
    required this.variantId,
    required this.productName,
    required this.productCode,
    required this.sku,
    required this.size,
    required this.color,
    required this.price,
  });

  final int variantId;
  final String productName;
  final String productCode;
  final String sku;
  final String size;
  final String color;
  final double price;

  String get label => '$productName $size / $color';
}

/// Producto del catalogo local con sus variantes (para el catalogo visual del punto de venta).
class LocalProduct {
  LocalProduct({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    required this.brand,
    required this.imageUrl,
    required this.variants,
    required this.hexByColor,
  });

  final int id;
  final String code;
  final String name;
  final String category;
  final String? brand;
  final String? imageUrl;
  final List<LocalVariant> variants;
  final Map<String, String?> hexByColor;

  double get minPrice => variants.map((v) => v.price).reduce((a, b) => a < b ? a : b);
  double get maxPrice => variants.map((v) => v.price).reduce((a, b) => a > b ? a : b);
  List<String> get colors => [...{for (final v in variants) v.color}];
  List<String> get sizes => [...{for (final v in variants) v.size}];
}

class LocalCustomer {
  LocalCustomer({required this.id, required this.fullName, this.documentNumber});
  final int id;
  final String fullName;
  final String? documentNumber;
}

/// Catalogo descargado al dispositivo (GET /offline/catalog, CU59) y datos del dueno de la base.
class CatalogStore extends ChangeNotifier {
  CatalogStore(this.local, this.api);

  final LocalDb local;
  final ApiClient api;

  CatalogInfo? info;
  Map<int, LocalVariant>? _index;

  Database get _db => local.db;

  /// El catalogo supero la antiguedad maxima de la empresa (offline_data_max_age_hours).
  bool get stale {
    final i = info;
    if (i == null) return false;
    return DateTime.now().toUtc().difference(i.generatedAt.toUtc()) > Duration(hours: i.maxAgeHours);
  }

  /// Asocia la base al usuario y empresa actuales; si eran otros, la vacia (RN-22).
  Future<void> ensureOwner(int userId, int? tenantId) async {
    final owner = await _meta('owner');
    if (owner != null && (owner['user_id'] != userId || owner['tenant_id'] != tenantId)) {
      await local.clearAll();
      _index = null;
    }
    await _setMeta('owner', {'user_id': userId, 'tenant_id': tenantId});
    await loadInfo();
  }

  Future<void> loadInfo() async {
    final raw = await _meta('catalog');
    info = raw == null ? null : CatalogInfo.fromJson(raw);
    notifyListeners();
  }

  /// Descarga el catalogo y reemplaza la copia local en una transaccion.
  Future<CatalogInfo> download() async {
    final catalog = await api.get('/offline/catalog') as Map<String, dynamic>;
    return save(catalog);
  }

  Future<CatalogInfo> save(Map<String, dynamic> catalog) async {
    final products = catalog['products'] as List;
    final newInfo = CatalogInfo(
      generatedAt: DateTime.parse(catalog['generated_at'] as String),
      maxAgeHours: catalog['max_age_hours'] as int,
      currency: catalog['currency'] as String,
      products: products.length,
    );
    await _db.transaction((tx) async {
      for (final t in ['products', 'stock', 'branches', 'customers']) {
        await tx.delete(t);
      }
      final batch = tx.batch();
      for (final prod in products.cast<Map<String, dynamic>>()) {
        final skus = [for (final v in prod['variants'] as List) v['sku']].join(' ');
        batch.insert('products', {
          'id': prod['id'],
          'name': prod['name'],
          'search': '${prod['name']} ${prod['code']} ${prod['brand'] ?? ''} $skus'.toLowerCase(),
          'data': jsonEncode(prod),
        });
      }
      for (final s in (catalog['stock'] as List).cast<Map<String, dynamic>>()) {
        batch.insert('stock', {'branch_id': s['branch_id'], 'product_variant_id': s['product_variant_id'], 'available': s['available_quantity']});
      }
      for (final b in (catalog['branches'] as List).cast<Map<String, dynamic>>()) {
        batch.insert('branches', {'id': b['id'], 'name': b['name'], 'city': b['city'], 'address': b['address']});
      }
      for (final c in (catalog['customers'] as List).cast<Map<String, dynamic>>()) {
        batch.insert('customers', {'id': c['id'], 'full_name': c['full_name'], 'document_number': c['document_number']});
      }
      batch.insert('meta', {'key': 'catalog', 'value': jsonEncode(newInfo.toJson())}, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    });
    _index = null;
    info = newInfo;
    notifyListeners();
    return newInfo;
  }

  Future<List<WorkBranch>> branches() async => [
        for (final r in await _db.query('branches', orderBy: 'name'))
          WorkBranch(id: r['id'] as int, name: r['name'] as String, city: r['city'] as String?, address: r['address'] as String?),
      ];

  /// Busca por nombre, codigo, marca o SKU.
  Future<List<LocalVariant>> search(String q, {int limit = 30}) async {
    final term = q.trim().toLowerCase();
    if (term.length < 2) return const [];
    final rows = await _db.query('products', where: 'search LIKE ?', whereArgs: ['%$term%'], orderBy: 'name');
    final out = <LocalVariant>[];
    for (final r in rows) {
      final prod = jsonDecode(r['data'] as String) as Map<String, dynamic>;
      for (final v in _variants(prod)) {
        if ('${prod['name']} ${prod['code']} ${prod['brand'] ?? ''} ${v.sku}'.toLowerCase().contains(term)) out.add(v);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// Todos los productos del catalogo descargado, ordenados por nombre.
  Future<List<LocalProduct>> products() async {
    final out = <LocalProduct>[];
    for (final r in await _db.query('products', orderBy: 'name')) {
      final prod = jsonDecode(r['data'] as String) as Map<String, dynamic>;
      final variants = _variants(prod).toList();
      if (variants.isEmpty) continue;
      out.add(LocalProduct(
        id: prod['id'] as int,
        code: prod['code'] as String,
        name: prod['name'] as String,
        category: prod['category'] as String,
        brand: prod['brand'] as String?,
        imageUrl: prod['cover_image_url'] as String?,
        variants: variants,
        hexByColor: {
          for (final v in (prod['variants'] as List).cast<Map<String, dynamic>>()) v['color'] as String: v['hex_code'] as String?,
        },
      ));
    }
    return out;
  }

  /// Disponible local por variante en una sucursal (ya descuenta lo vendido sin conexion).
  Future<Map<int, int>> stockOf(int branchId) async => {
        for (final r in await _db.query('stock', where: 'branch_id = ?', whereArgs: [branchId]))
          r['product_variant_id'] as int: r['available'] as int,
      };

  Future<LocalVariant?> variant(int id) async => (await _variantIndex())[id];

  Future<int> available(int branchId, int variantId) async {
    final rows = await _db.query('stock',
        columns: ['available'], where: 'branch_id = ? AND product_variant_id = ?', whereArgs: [branchId, variantId]);
    return rows.isEmpty ? 0 : rows.first['available'] as int;
  }

  /// Refleja lo vendido o apartado sin conexion (no toca el servidor; nunca baja de cero).
  Future<void> adjustStock(int branchId, int variantId, int delta) async {
    final current = await available(branchId, variantId);
    final next = current + delta < 0 ? 0 : current + delta;
    await _db.insert('stock', {'branch_id': branchId, 'product_variant_id': variantId, 'available': next},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LocalCustomer>> searchCustomers(String q, {int limit = 10}) async {
    final term = q.trim().toLowerCase();
    if (term.length < 2) return const [];
    final rows = await _db.query('customers',
        where: "LOWER(full_name) LIKE ? OR LOWER(COALESCE(document_number, '')) LIKE ?",
        whereArgs: ['%$term%', '%$term%'],
        limit: limit);
    return [for (final r in rows) LocalCustomer(id: r['id'] as int, fullName: r['full_name'] as String, documentNumber: r['document_number'] as String?)];
  }

  Future<void> clear() async {
    await local.clearAll();
    _index = null;
    info = null;
    notifyListeners();
  }

  Iterable<LocalVariant> _variants(Map<String, dynamic> prod) sync* {
    for (final v in (prod['variants'] as List).cast<Map<String, dynamic>>()) {
      yield LocalVariant(
        variantId: v['id'] as int,
        productName: prod['name'] as String,
        productCode: prod['code'] as String,
        sku: v['sku'] as String,
        size: v['size'] as String,
        color: v['color'] as String,
        price: (v['price'] as num).toDouble(),
      );
    }
  }

  Future<Map<int, LocalVariant>> _variantIndex() async {
    if (_index != null) return _index!;
    final index = <int, LocalVariant>{};
    for (final r in await _db.query('products')) {
      for (final v in _variants(jsonDecode(r['data'] as String) as Map<String, dynamic>)) {
        index[v.variantId] = v;
      }
    }
    return _index = index;
  }

  Future<Map<String, dynamic>?> _meta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String) as Map<String, dynamic>;
  }

  Future<void> _setMeta(String key, Object value) =>
      _db.insert('meta', {'key': key, 'value': jsonEncode(value)}, conflictAlgorithm: ConflictAlgorithm.replace);
}
