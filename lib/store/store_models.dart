/// Catalogo de la tienda del cliente (GET /store/catalog, app/schemas/store.py).
class StoreVariant {
  StoreVariant({
    required this.id,
    required this.sku,
    required this.size,
    required this.color,
    required this.hexCode,
    required this.price,
    required this.available,
    required this.availability,
  });

  final int id;
  final String sku;
  final String size;
  final String color;
  final String? hexCode;
  final double price;
  final int available;

  /// Disponible por sucursal: {branch_id: cantidad}.
  final Map<int, int> availability;

  factory StoreVariant.fromJson(Map<String, dynamic> j) => StoreVariant(
        id: j['id'] as int,
        sku: j['sku'] as String,
        size: j['size'] as String,
        color: j['color'] as String,
        hexCode: j['hex_code'] as String?,
        price: (j['price'] as num).toDouble(),
        available: j['available'] as int,
        availability: {
          for (final a in (j['availability'] as List).cast<Map<String, dynamic>>()) a['branch_id'] as int: a['available'] as int,
        },
      );
}

class StoreProduct {
  StoreProduct({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.brand,
    required this.categoryId,
    required this.category,
    required this.imageUrl,
    required this.minPrice,
    required this.maxPrice,
    required this.isNew,
    required this.createdAt,
    required this.available,
    required this.variants,
  });

  final int id;
  final String code;
  final String name;
  final String? description;
  final String? brand;
  final int categoryId;
  final String category;
  final String? imageUrl;
  final double minPrice;
  final double maxPrice;
  final bool isNew;
  final String createdAt;
  final int available;
  final List<StoreVariant> variants;

  List<String> get colors => [...{for (final v in variants) v.color}];
  List<String> get sizes => [...{for (final v in variants) v.size}];
  String? hexOf(String color) => variants.firstWhere((v) => v.color == color).hexCode;

  factory StoreProduct.fromJson(Map<String, dynamic> j) => StoreProduct(
        id: j['id'] as int,
        code: j['code'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        brand: j['brand'] as String?,
        categoryId: j['category_id'] as int,
        category: j['category'] as String,
        imageUrl: j['cover_image_url'] as String?,
        minPrice: (j['min_price'] as num).toDouble(),
        maxPrice: (j['max_price'] as num).toDouble(),
        isNew: j['is_new'] as bool,
        createdAt: j['created_at'] as String,
        available: j['available'] as int,
        variants: [for (final v in (j['variants'] as List).cast<Map<String, dynamic>>()) StoreVariant.fromJson(v)],
      );
}

class StoreBranch {
  StoreBranch(this.id, this.name, this.city);
  final int id;
  final String name;
  final String? city;
}

class StoreCategory {
  StoreCategory(this.id, this.name, this.count);
  final int id;
  final String name;
  final int count;
}

class StoreCatalog {
  StoreCatalog({
    required this.tenantName,
    required this.reservationHours,
    required this.canReserve,
    required this.branches,
    required this.categories,
    required this.products,
  });

  final String tenantName;
  final int reservationHours;
  final bool canReserve;
  final List<StoreBranch> branches;
  final List<StoreCategory> categories;
  final List<StoreProduct> products;

  String branchName(int id) => branches.where((b) => b.id == id).firstOrNull?.name ?? 'Sucursal $id';

  factory StoreCatalog.fromJson(Map<String, dynamic> j) => StoreCatalog(
        tenantName: j['tenant_name'] as String,
        reservationHours: j['reservation_hours'] as int,
        canReserve: j['can_reserve'] as bool,
        branches: [
          for (final b in (j['branches'] as List).cast<Map<String, dynamic>>())
            StoreBranch(b['id'] as int, b['name'] as String, b['city'] as String?),
        ],
        categories: [
          for (final c in (j['categories'] as List).cast<Map<String, dynamic>>())
            StoreCategory(c['id'] as int, c['name'] as String, c['product_count'] as int),
        ],
        products: [for (final p in (j['products'] as List).cast<Map<String, dynamic>>()) StoreProduct.fromJson(p)],
      );
}
