import 'package:flutter/foundation.dart';

import '../ui/format.dart';
import 'pickers.dart';

class CartLine {
  CartLine(this.item, [this.quantity = 1]);
  final PickedItem item;
  int quantity;

  String? get problem {
    if (quantity < 1 || quantity > 1000) return 'Cantidad entre 1 y 1000.';
    if (item.available != null && quantity > item.available!) return 'Solo hay ${item.available} disponibles.';
    return null;
  }
}

/// Carrito del punto de venta, compartido entre el catalogo visual y la pantalla de cobro.
/// Vive en memoria mientras la app esta abierta: si se corta internet no se pierde y se puede
/// cobrar al contado sin conexion (la venta va a la cola y se sincroniza al volver la red).
class SaleCart extends ChangeNotifier {
  final List<CartLine> lines = [];

  int get count => lines.fold(0, (n, l) => n + l.quantity);
  double get total => round2(lines.fold<double>(0, (s, l) => s + l.item.price * l.quantity));

  void add(PickedItem item, [int quantity = 1]) {
    final existing = lines.where((l) => l.item.variantId == item.variantId).firstOrNull;
    if (existing != null) {
      existing.quantity += quantity;
    } else {
      lines.add(CartLine(item, quantity));
    }
    notifyListeners();
  }

  void increment(CartLine line) {
    line.quantity++;
    notifyListeners();
  }

  void decrement(CartLine line) {
    if (line.quantity > 1) {
      line.quantity--;
    } else {
      lines.remove(line);
    }
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }
}
