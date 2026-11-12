import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import 'store_models.dart';

class CartLine {
  CartLine({required this.product, required this.variant, required this.quantity});

  StoreProduct product;
  StoreVariant variant;
  int quantity;

  double get subtotal => variant.price * quantity;
}

/// Catalogo de la tienda y carrito del cliente. El carrito se confirma como reserva en una
/// sucursal (CU28): el servidor valida stock y precios; el pago se hace al retirar.
class CartService extends ChangeNotifier {
  CartService(this._api);

  final ApiClient _api;

  StoreCatalog? catalog;
  final List<CartLine> lines = [];

  int get count => lines.fold(0, (n, l) => n + l.quantity);
  double get total => lines.fold(0, (t, l) => t + l.subtotal);

  Future<StoreCatalog> load() async {
    final c = StoreCatalog.fromJson(await _api.get('/store/catalog') as Map<String, dynamic>);
    catalog = c;
    // precios vigentes; se quitan las variantes que ya no se venden
    final variants = {for (final p in c.products) for (final v in p.variants) v.id: (p, v)};
    lines.removeWhere((l) => !variants.containsKey(l.variant.id));
    for (final l in lines) {
      final (p, v) = variants[l.variant.id]!;
      l
        ..product = p
        ..variant = v;
    }
    notifyListeners();
    return c;
  }

  void add(StoreProduct product, StoreVariant variant, int quantity) {
    final existing = lines.where((l) => l.variant.id == variant.id).firstOrNull;
    if (existing != null) {
      existing.quantity = (existing.quantity + quantity).clamp(1, 50);
    } else {
      lines.add(CartLine(product: product, variant: variant, quantity: quantity.clamp(1, 50)));
    }
    notifyListeners();
  }

  void setQuantity(int variantId, int quantity) {
    if (quantity < 1) return remove(variantId);
    lines.firstWhere((l) => l.variant.id == variantId).quantity = quantity.clamp(1, 50);
    notifyListeners();
  }

  void remove(int variantId) {
    lines.removeWhere((l) => l.variant.id == variantId);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  /// Sucursal sugerida: la primera que tiene todo el carrito.
  int? suggestedBranch() {
    final c = catalog;
    if (c == null || c.branches.isEmpty) return null;
    for (final b in c.branches) {
      if (lines.every((l) => (l.variant.availability[b.id] ?? 0) >= l.quantity)) return b.id;
    }
    return c.branches.first.id;
  }

  /// Confirma el carrito como reserva (POST /reservations). Devuelve la reserva creada.
  Future<Map<String, dynamic>> reserve(int branchId, String? notes) async {
    final r = await _api.post('/reservations', body: {
      'branch_id': branchId,
      'customer_id': null,
      'items': [for (final l in lines) {'product_variant_id': l.variant.id, 'quantity': l.quantity}],
      'notes': (notes == null || notes.trim().isEmpty) ? null : notes.trim(),
    }) as Map<String, dynamic>;
    clear();
    return r;
  }

  void reset() {
    catalog = null;
    lines.clear();
    notifyListeners();
  }
}
