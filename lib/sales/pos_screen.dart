import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../branch/branch_service.dart';
import '../core/api_client.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import '../offline/catalog_store.dart';
import '../offline/offline_bootstrap.dart';
import '../offline/operation_queue.dart';
import '../ui/format.dart';
import 'pickers.dart';
import 'receipt_screen.dart';
import 'sale_cart.dart';

const paymentLabels = {'CASH': 'Efectivo', 'CARD': 'Tarjeta', 'QR': 'QR', 'TRANSFER': 'Transferencia'};
final _moneyInput = RegExp(r'^\d+(\.\d{1,2})?$');

/// CU35 venta presencial, CU36 pago, CU37 comprobante. Sin conexion (CU61, RN-06): solo
/// efectivo, con el catalogo descargado; queda en la cola con comprobante provisional.
/// Tarjeta, QR y transferencia se cobran fuera del sistema; aqui se registra el metodo y la referencia.
class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  PickedCustomer? _customer;
  String _method = 'CASH';
  final _received = TextEditingController();
  final _reference = TextEditingController();
  final _taxId = TextEditingController();
  final _taxName = TextEditingController();
  bool _saving = false;
  String? _error;
  int? _errorVariant;

  @override
  void dispose() {
    for (final c in [_received, _reference, _taxId, _taxName]) {
      c.dispose();
    }
    super.dispose();
  }

  SaleCart get _sale => context.read<SaleCart>();
  List<CartLine> get _cart => _sale.lines;
  double get _total => _sale.total;

  String? _offlineBlock(bool offline) {
    if (!offline) return null;
    final boot = context.read<OfflineBootstrap>();
    if (!boot.canOperateOffline) return 'Sin conexión: su rol o el plan de la empresa no permiten vender sin conexión.';
    if (context.read<CatalogStore>().info == null) return 'Sin conexión y sin catálogo descargado en este dispositivo: no se puede vender.';
    return null;
  }

  void _add(PickedItem item) {
    setState(() => _error = null);
    _sale.add(item);
  }

  double? _change() {
    final r = _received.text.trim();
    if (_method != 'CASH' || !_moneyInput.hasMatch(r)) return null;
    return round2(double.parse(r) - _total);
  }

  Future<void> _submit() async {
    final branch = context.read<BranchService>().selected;
    final offline = !context.read<ConnectivityService>().online;
    setState(() {
      _error = null;
      _errorVariant = null;
    });
    if (branch == null) return;
    final block = _offlineBlock(offline);
    if (block != null) return setState(() => _error = block);
    if (_cart.isEmpty) return setState(() => _error = 'Agregue al menos un producto.');
    if (_cart.any((l) => l.problem != null)) return setState(() => _error = 'Revise las cantidades marcadas.');
    final method = offline ? 'CASH' : _method;
    final received = _received.text.trim();
    if (method == 'CASH' && received.isNotEmpty) {
      if (!_moneyInput.hasMatch(received)) return setState(() => _error = 'Importe recibido inválido: use hasta 2 decimales.');
      if (double.parse(received) < _total) return setState(() => _error = 'El efectivo recibido no cubre el total.');
    }

    setState(() => _saving = true);
    try {
      final result = offline ? await _saveOffline(branch, received) : await _saveOnline(branch.id, method, received);
      if (!mounted) return;
      // la venta ya quedo registrada (o en la cola): el carrito se vacia para no cobrarla dos veces
      _reset();
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(result: result)));
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        final d = e.details;
        if (e.code == 'INSUFFICIENT_STOCK' && d is Map) _errorVariant = d['product_variant_id'] as int?;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<ReceiptResult> _saveOnline(int branchId, String method, String received) async {
    final api = context.read<ApiClient>();
    final sale = await api.post('/sales', body: {
      'branch_id': branchId,
      'customer_id': _customer?.id,
      'reservation_id': null,
      'items': [for (final l in _cart) {'product_variant_id': l.item.variantId, 'quantity': l.quantity}],
      'payment': {
        'method': method,
        'amount_received': method == 'CASH' && received.isNotEmpty ? double.parse(received) : null,
        'external_reference': method != 'CASH' && _reference.text.trim().isNotEmpty ? _reference.text.trim() : null,
      },
      'tax_id': _blank(_taxId.text),
      'tax_name': _blank(_taxName.text),
    }) as Map<String, dynamic>;
    final receipt = await api.get('/sales/${sale['id']}/receipt') as Map<String, dynamic>;
    return ReceiptResult(receipt: receipt, saleCode: sale['sale_code'] as String);
  }

  /// Venta sin conexion: a la cola con el precio cobrado (RN-06, RN-13) y comprobante provisional.
  Future<ReceiptResult> _saveOffline(WorkBranch branch, String received) async {
    final auth = context.read<AuthService>();
    final queue = context.read<OperationQueue>();
    final catalog = context.read<CatalogStore>();
    final total = _total;
    final paid = received.isEmpty ? total : double.parse(received);
    final units = _cart.fold<int>(0, (n, l) => n + l.quantity);
    final op = await queue.enqueue(
      type: 'SALE',
      branchId: branch.id,
      userId: auth.me!.id,
      summary: '$units prendas · ${money(total)}',
      payload: {
        'customer_id': _customer?.id,
        'items': [for (final l in _cart) {'product_variant_id': l.item.variantId, 'quantity': l.quantity, 'unit_price': l.item.price}],
        'payment': {'method': 'CASH', 'amount_received': received.isEmpty ? null : paid},
        'tax_id': _blank(_taxId.text),
        'tax_name': _blank(_taxName.text),
      },
    );
    for (final l in _cart) {
      await catalog.adjustStock(branch.id, l.item.variantId, -l.quantity);
    }
    return ReceiptResult(
      offlineCode: op.provisionalCode,
      receipt: {
        'receipt_code': op.provisionalCode,
        'receipt_type': 'RECEIPT',
        'is_provisional': true,
        'reference': op.provisionalCode,
        'company': {'legal_name': auth.me?.tenant?.legalName ?? '', 'nit': ''},
        'branch': branch.name,
        'issued_at': op.registeredAt,
        'issued_by': auth.me?.fullName,
        'tax_id': _blank(_taxId.text),
        'tax_name': _blank(_taxName.text),
        'items': [
          for (final l in _cart)
            {'description': l.item.label, 'sku': l.item.sku, 'quantity': l.quantity, 'unit_price': l.item.price, 'subtotal': round2(l.item.price * l.quantity)},
        ],
        'total_amount': total,
        'payments': [
          {'payment_method': 'CASH', 'amount': total, 'amount_received': paid, 'change_amount': round2(paid - total), 'external_reference': null},
        ],
      },
    );
  }

  void _reset() => setState(() {
        _sale.clear();
        _customer = null;
        _method = 'CASH';
        for (final c in [_received, _reference, _taxId, _taxName]) {
          c.clear();
        }
        _error = null;
      });

  String? _blank(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final offline = !context.watch<ConnectivityService>().online;
    final auth = context.watch<AuthService>();
    final branch = context.watch<BranchService>().selected;
    final catalog = context.watch<CatalogStore>();
    final api = context.read<ApiClient>();
    final block = _offlineBlock(offline);
    final scheme = Theme.of(context).colorScheme;
    final change = _change();
    final method = offline ? 'CASH' : _method;
    context.watch<SaleCart>();

    return Scaffold(
      appBar: AppBar(title: const Text('Carrito y cobro'), actions: [
        TextButton.icon(
          key: const Key('open-catalog'),
          onPressed: () => Navigator.of(context).pushNamed('/catalog'),
          icon: const Icon(Icons.grid_view),
          label: const Text('Catálogo'),
        ),
      ]),
      body: branch == null
          // sin conexion y sin catalogo no hay sucursales: se explica el motivo real
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(block ?? 'Elija una sucursal de trabajo en el inicio.', key: const Key('no-branch'), textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Sucursal ${branch.name}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (!offline && auth.readOnly) _notice(scheme.tertiaryContainer, 'La suscripción no está vigente: no se pueden registrar ventas.'),
                if (offline)
                  _notice(block == null ? scheme.tertiaryContainer : scheme.errorContainer,
                      block ??
                          'Sin conexión: la venta se guarda en el teléfono y se sincroniza al volver la conexión. Solo efectivo.'
                              '${catalog.stale ? ' El catálogo está desactualizado: los precios se verificarán al sincronizar.' : ''}',
                      key: const Key('offline-banner')),
                SearchPicker<PickedItem>(
                  label: 'Agregar prenda',
                  search: (q) => searchItems(query: q, branchId: branch.id, offline: offline, api: api, catalog: catalog),
                  itemBuilder: itemTile,
                  enabledFor: (i) => i.available != 0,
                  onPicked: _add,
                ),
                const SizedBox(height: 12),
                for (final l in _cart)
                  Card(
                    key: Key('line-${l.item.variantId}'),
                    color: (l.problem != null || _errorVariant == l.item.variantId) ? scheme.errorContainer : null,
                    child: ListTile(
                      title: Text(l.item.label),
                      subtitle: Text('${l.item.sku} · ${money(l.item.price)}${l.problem == null ? '' : '\n${l.problem}'}'),
                      trailing: SizedBox(
                        width: 150,
                        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          IconButton(key: Key('minus-${l.item.variantId}'), icon: const Icon(Icons.remove), onPressed: () => _sale.decrement(l)),
                          Text('${l.quantity}', key: Key('qty-${l.item.variantId}')),
                          IconButton(key: Key('plus-${l.item.variantId}'), icon: const Icon(Icons.add), onPressed: () => _sale.increment(l)),
                        ]),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (_customer == null)
                  SearchPicker<PickedCustomer>(
                    label: 'Cliente registrado (opcional)',
                    search: (q) => searchCustomers(query: q, offline: offline, api: api, catalog: catalog),
                    itemBuilder: (c) => Text('${c.fullName}${c.document == null ? '' : ' · ${c.document}'}'),
                    onPicked: (c) => setState(() => _customer = c),
                  )
                else
                  Chip(label: Text(_customer!.fullName), onDeleted: () => setState(() => _customer = null)),
                const Divider(height: 32),
                Text('Total ${money(_total)}', key: const Key('total'), style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('method'),
                  initialValue: method,
                  decoration: const InputDecoration(labelText: 'Método de pago', border: OutlineInputBorder()),
                  items: [for (final e in paymentLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: offline ? null : (v) => setState(() => _method = v!),
                ),
                const SizedBox(height: 12),
                if (method == 'CASH')
                  TextField(
                    key: const Key('received'),
                    controller: _received,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Efectivo recibido (opcional)',
                      border: const OutlineInputBorder(),
                      helperText: change == null ? null : (change >= 0 ? 'Cambio: ${money(change)}' : 'Faltan ${money(-change)}'),
                    ),
                  )
                else
                  TextField(
                    key: const Key('reference'),
                    controller: _reference,
                    decoration: const InputDecoration(
                        labelText: 'Referencia del cobro', helperText: 'Se cobra en el datáfono o banco; aquí solo se registra.', border: OutlineInputBorder()),
                  ),
                const SizedBox(height: 12),
                TextField(key: const Key('taxId'), controller: _taxId, decoration: const InputDecoration(labelText: 'NIT/CI para el comprobante', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: _taxName, decoration: const InputDecoration(labelText: 'Nombre o razón social', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                if (_error != null) _notice(scheme.errorContainer, _error!, key: const Key('pos-error')),
                FilledButton(
                  key: const Key('confirm'),
                  onPressed: _saving || block != null || (!offline && auth.readOnly) || _cart.isEmpty ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_saving ? 'Registrando…' : (offline ? 'Pagar al contado (sin conexión)' : 'Pagar y confirmar venta')),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _notice(Color color, String text, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Text(text),
      );
}
