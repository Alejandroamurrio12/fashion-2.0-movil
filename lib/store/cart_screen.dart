import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import '../ui/format.dart';
import 'cart.dart';
import '../ui/product_photo.dart';

/// Carrito del cliente: se confirma como reserva en una sucursal (CU28). Se aparta el stock por el
/// plazo de la empresa y se paga al retirar en la tienda.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  int? _branch;
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _done;

  @override
  void initState() {
    super.initState();
    _branch = context.read<CartService>().suggestedBranch();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  int _availableAt(CartLine l) => _branch == null ? 0 : (l.variant.availability[_branch] ?? 0);

  Future<void> _confirm() async {
    final cart = context.read<CartService>();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final r = await cart.reserve(_branch!, _notes.text);
      _done = r;
      _notes.clear();
    } on ApiError catch (e) {
      _error = e.message;
      try {
        await cart.load(); // disponibilidad actualizada
      } on ApiError {
        // se mantiene el mensaje original
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartService>();
    final online = context.watch<ConnectivityService>().online;
    final catalog = cart.catalog;
    final theme = Theme.of(context);
    final shortages = cart.lines.where((l) => _availableAt(l) < l.quantity).toList();
    final canConfirm = catalog != null && catalog.canReserve && online && cart.lines.isNotEmpty && _branch != null && shortages.isEmpty && !_saving;

    return Scaffold(
      appBar: AppBar(title: const Text('Mi carrito')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_done != null)
            Card(
              key: const Key('reservation-done'),
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('¡Reserva confirmada!', style: theme.textTheme.titleMedium),
                  Text(_done!['reservation_code'] as String, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text('Retire en ${catalog?.branchName(_done!['branch_id'] as int) ?? ''} hasta el ${dateTime(_done!['expires_at'] as String)}. '
                      'Pague ${money(_done!['total_amount'] as num)} en la tienda.'),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Volver a la tienda')),
                ]),
              ),
            ),
          if (cart.lines.isEmpty && _done == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Su carrito está vacío.'))),
          for (final l in cart.lines)
            Card(
              key: Key('line-${l.variant.id}'),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(width: 64, height: 78, child: ProductPhoto(id: l.product.id, name: l.product.name, url: l.product.imageUrl, fontSize: 20)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.product.name, style: theme.textTheme.titleSmall),
                      Text('${l.variant.color} · Talla ${l.variant.size}', style: theme.textTheme.bodySmall),
                      Text('${money(l.variant.price)} c/u', style: theme.textTheme.bodySmall),
                      if (_branch != null && _availableAt(l) < l.quantity)
                        Text('Solo ${_availableAt(l)} disponibles en ${catalog?.branchName(_branch!)}',
                            key: Key('short-${l.variant.id}'), style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                      Row(children: [
                        IconButton(key: Key('minus-${l.variant.id}'), onPressed: () => cart.setQuantity(l.variant.id, l.quantity - 1), icon: const Icon(Icons.remove_circle_outline)),
                        Text('${l.quantity}'),
                        IconButton(key: Key('plus-${l.variant.id}'), onPressed: () => cart.setQuantity(l.variant.id, l.quantity + 1), icon: const Icon(Icons.add_circle_outline)),
                        Expanded(
                          child: Text(money(l.subtotal),
                              textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ]),
                  ),
                  IconButton(tooltip: 'Quitar', onPressed: () => cart.remove(l.variant.id), icon: const Icon(Icons.close)),
                ]),
              ),
            ),
          if (cart.lines.isNotEmpty && catalog != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('Total (${cart.count} prendas)', overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium)),
              Text(money(cart.total), key: const Key('cart-total'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('pickup-branch'),
              initialValue: _branch,
              decoration: const InputDecoration(labelText: 'Retirar en', border: OutlineInputBorder()),
              items: [for (final b in catalog.branches) DropdownMenuItem(value: b.id, child: Text(b.name))],
              onChanged: (v) => setState(() => _branch = v),
            ),
            const SizedBox(height: 8),
            TextField(controller: _notes, maxLength: 500, decoration: const InputDecoration(labelText: 'Notas (opcional)', border: OutlineInputBorder())),
            Text('Se aparta por ${catalog.reservationHours} horas. El pago se hace en la tienda al retirar.', style: theme.textTheme.bodySmall),
            if (!catalog.canReserve) Text('Su empresa no tiene habilitadas las reservas.', style: TextStyle(color: theme.colorScheme.error)),
            if (!online) Text('Sin conexión: la reserva necesita internet.', style: TextStyle(color: theme.colorScheme.error)),
            if (_error != null) Text(_error!, key: const Key('cart-error'), style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('confirm-reservation'),
              onPressed: canConfirm ? _confirm : null,
              child: Text(_saving ? 'Reservando…' : 'Confirmar reserva'),
            ),
          ],
        ],
      ),
    );
  }
}
