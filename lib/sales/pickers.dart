import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/api_error.dart';
import '../offline/catalog_store.dart';
import '../ui/format.dart';

/// Prenda elegida para vender, reservar o cambiar. available = null si no se conoce.
class PickedItem {
  const PickedItem({required this.variantId, required this.label, required this.sku, required this.price, this.available});

  final int variantId;
  final String label;
  final String sku;
  final double price;
  final int? available;
}

class PickedCustomer {
  const PickedCustomer({required this.id, required this.fullName, this.document});
  final int id;
  final String fullName;
  final String? document;
}

/// Busca prendas: con conexion en las existencias de la sucursal (/inventory), sin conexion en
/// el catalogo descargado con su stock local.
Future<List<PickedItem>> searchItems({
  required String query,
  required int branchId,
  required bool offline,
  required ApiClient api,
  required CatalogStore catalog,
}) async {
  final q = query.trim();
  if (q.length < 2) return const [];
  if (offline) {
    final found = await catalog.search(q);
    return [
      for (final v in found)
        PickedItem(variantId: v.variantId, label: v.label, sku: v.sku, price: v.price, available: await catalog.available(branchId, v.variantId)),
    ];
  }
  final rows = await api.get('/inventory', query: {'branch_id': branchId, 'q': q, 'limit': 50}) as List;
  return [
    for (final r in rows.cast<Map<String, dynamic>>())
      PickedItem(
        variantId: r['product_variant_id'] as int,
        label: '${r['product_name']} ${r['size']} / ${r['color']}',
        sku: r['sku'] as String,
        price: (r['price'] as num).toDouble(),
        available: r['available_quantity'] as int,
      ),
  ];
}

Future<List<PickedCustomer>> searchCustomers({
  required String query,
  required bool offline,
  required ApiClient api,
  required CatalogStore catalog,
}) async {
  final q = query.trim();
  if (q.length < 2) return const [];
  if (offline) {
    return [for (final c in await catalog.searchCustomers(q)) PickedCustomer(id: c.id, fullName: c.fullName, document: c.documentNumber)];
  }
  final rows = await api.get('/customers', query: {'q': q, 'limit': 10}) as List;
  return [
    for (final r in rows.cast<Map<String, dynamic>>())
      PickedCustomer(id: r['id'] as int, fullName: r['full_name'] as String, document: (r['document_number'] ?? r['email']) as String?),
  ];
}

/// Campo de busqueda con resultados debajo (espera 300 ms entre teclas).
class SearchPicker<T> extends StatefulWidget {
  const SearchPicker({
    super.key,
    required this.label,
    required this.search,
    required this.itemBuilder,
    required this.onPicked,
    this.enabledFor,
  });

  final String label;
  final Future<List<T>> Function(String q) search;
  final Widget Function(T item) itemBuilder;
  final void Function(T item) onPicked;
  final bool Function(T item)? enabledFor;

  @override
  State<SearchPicker<T>> createState() => _SearchPickerState<T>();
}

class _SearchPickerState<T> extends State<SearchPicker<T>> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<T> _results = const [];
  String? _error;
  bool _searched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(q));
  }

  Future<void> _run(String q) async {
    try {
      final r = await widget.search(q);
      if (!mounted) return;
      setState(() {
        _results = r;
        _error = null;
        _searched = q.trim().length >= 2;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: Key('search-${widget.label}'),
          controller: _controller,
          onChanged: _changed,
          decoration: InputDecoration(labelText: widget.label, prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder()),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_searched && _results.isEmpty && _error == null) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Sin resultados.')),
        for (final item in _results)
          Card(
            margin: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: (widget.enabledFor?.call(item) ?? true)
                  ? () {
                      widget.onPicked(item);
                      _controller.clear();
                      setState(() {
                        _results = const [];
                        _searched = false;
                      });
                    }
                  : null,
              child: Padding(padding: const EdgeInsets.all(12), child: widget.itemBuilder(item)),
            ),
          ),
      ],
    );
  }
}

Widget itemTile(PickedItem i) => Row(
      children: [
        Expanded(child: Text(i.label)),
        Text('${money(i.price)}${i.available == null ? '' : ' · ${i.available == 0 ? 'sin stock' : '${i.available} disp.'}'}'),
      ],
    );
