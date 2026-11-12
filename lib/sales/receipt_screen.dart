import 'package:flutter/material.dart';

import '../ui/format.dart';
import 'pos_screen.dart';

class ReceiptResult {
  const ReceiptResult({required this.receipt, this.saleCode, this.offlineCode});

  /// Formato de ReceiptOut del backend (o el provisional armado en el telefono).
  final Map<String, dynamic> receipt;
  final String? saleCode;
  final String? offlineCode;

  bool get offline => offlineCode != null;
}

/// CU37 Comprobante de venta (provisional si se emitio sin conexion).
class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({super.key, required this.result});

  final ReceiptResult result;

  @override
  Widget build(BuildContext context) {
    final r = result.receipt;
    final company = r['company'] as Map<String, dynamic>;
    final payments = (r['payments'] as List).cast<Map<String, dynamic>>();
    final cash = payments.where((p) => p['payment_method'] == 'CASH').firstOrNull;
    final change = cash == null ? 0 : (cash['change_amount'] as num);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(result.offline ? 'Venta guardada sin conexión' : 'Venta registrada')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (result.offline)
            Card(
              color: scheme.tertiaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Se sincronizará automáticamente al volver la conexión.'),
              ),
            ),
          if (change > 0)
            Card(
              key: const Key('change'),
              color: scheme.primaryContainer,
              child: Padding(padding: const EdgeInsets.all(12), child: Text('Cambio a entregar: ${money(change)}', style: Theme.of(context).textTheme.titleMedium)),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(company['legal_name'] as String, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  if ((company['nit'] as String? ?? '').isNotEmpty) Text('NIT ${company['nit']}', textAlign: TextAlign.center),
                  if (r['branch'] != null) Text('Sucursal ${r['branch']}', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text('Comprobante de venta ${r['receipt_code']}', key: const Key('receipt-code'), style: Theme.of(context).textTheme.titleSmall),
                  if (r['is_provisional'] == true) const Text('Provisional (emitido sin conexión)', key: Key('provisional')),
                  Text('Fecha: ${dateTime(r['issued_at'] as String?)}'),
                  if (r['issued_by'] != null) Text('Atendido por: ${r['issued_by']}'),
                  if (r['tax_id'] != null) Text('NIT/CI cliente: ${r['tax_id']} ${r['tax_name'] ?? ''}'),
                  const Divider(),
                  for (final i in (r['items'] as List).cast<Map<String, dynamic>>())
                    Row(children: [
                      Expanded(child: Text('${i['quantity']} × ${i['description']}')),
                      Text(money(i['subtotal'] as num)),
                    ]),
                  const Divider(),
                  Row(children: [
                    const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                    Text(money(r['total_amount'] as num), key: const Key('receipt-total'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  for (final p in payments)
                    Text('Pago: ${paymentLabels[p['payment_method']] ?? p['payment_method']} ${money(p['amount'] as num)}'
                        '${p['external_reference'] == null ? '' : ' · ref. ${p['external_reference']}'}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Nueva venta')),
        ],
      ),
    );
  }
}
