import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/api_error.dart';
import '../ui/format.dart';
import 'operations_screen.dart';

const conflictLabels = {'STOCK': 'Stock insuficiente', 'PRICE': 'Precio distinto', 'SUBSCRIPTION': 'Suscripción no vigente', 'OTHER': 'Otro motivo'};

const decisionLabels = {
  'ACCEPT_PARTIAL': 'Aceptar lo disponible',
  'ADJUST_INVENTORY': 'Ajustar inventario y confirmar',
  'CANCEL': 'Cancelar la operación',
  'RESCHEDULE': 'Reprogramar la reserva',
  'ACCEPT_PRICE': 'Aceptar el precio cobrado',
  'RETRY': 'Reintentar',
};

const decisionHelp = {
  'ACCEPT_PARTIAL': 'Registra la operación solo con las unidades que hay en stock.',
  'ADJUST_INVENTORY': 'Ajusta el inventario por la diferencia (el stock físico existía) y confirma la operación completa.',
  'CANCEL': 'No se registra la operación; el cliente se atiende aparte.',
  'RESCHEDULE': 'Mantiene la reserva para cuando llegue el stock.',
  'ACCEPT_PRICE': 'La venta ya está confirmada con el precio cobrado; se deja constancia de la diferencia.',
  'RETRY': 'Vuelve a procesar la operación (por ejemplo, tras renovar la suscripción).',
};

/// CU63 Resolver conflictos de sincronizacion (encargado de su sucursal o administrador).
class ConflictsScreen extends StatefulWidget {
  const ConflictsScreen({super.key});

  @override
  State<ConflictsScreen> createState() => _ConflictsScreenState();
}

class _ConflictsScreenState extends State<ConflictsScreen> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loaded = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await context.read<ApiClient>().get('/sync/conflicts', query: {'status': 'OPEN'}) as List;
      setState(() {
        _rows = rows.cast<Map<String, dynamic>>();
        _loaded = true;
        _error = null;
      });
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _resolve(Map<String, dynamic> c, String decision, String notes) async {
    try {
      await context.read<ApiClient>().post('/sync/conflicts/${c['id']}/resolve', body: {'decision': decision, 'notes': notes.trim().isEmpty ? null : notes.trim()});
      setState(() {
        _rows = _rows.where((r) => r['id'] != c['id']).toList();
        _notice = 'Conflicto #${c['id']} resuelto: ${decisionLabels[decision]}.';
      });
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _open(Map<String, dynamic> c) {
    final notes = TextEditingController();
    final op = c['operation'] as Map<String, dynamic>;
    final lines = ((c['detail'] as Map?)?['lines'] as List? ?? const []).cast<Map<String, dynamic>>();
    final isPrice = c['conflict_type'] == 'PRICE';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${conflictLabels[c['conflict_type']] ?? c['conflict_type']} · ${operationLabels[op['operation_type']] ?? op['operation_type']}',
                  style: Theme.of(ctx).textTheme.titleMedium),
              Text(messageFor(c['reason_code'] as String) ?? c['reason_code'] as String),
              Text('Sucursal ${c['branch_name'] ?? '—'} · registrada por ${op['user_name'] ?? '—'} el ${dateTime(op['registered_at'] as String?)}'),
              if (c['price_difference'] != null) Text('Diferencia de precio: ${money(c['price_difference'] as num)}'),
              const SizedBox(height: 8),
              for (final l in lines)
                Text(isPrice
                    ? 'Variante #${l['product_variant_id']}: ${l['quantity']} u. cobradas a ${money(l['charged_price'] as num)}, vigente ${money(l['current_price'] as num)}'
                    : 'Variante #${l['product_variant_id']}: pedidas ${l['requested']}, disponibles ${l['available']}',
                    key: Key('line-${l['product_variant_id']}')),
              const SizedBox(height: 8),
              TextField(controller: notes, decoration: const InputDecoration(labelText: 'Observaciones (opcional)', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              for (final d in (c['allowed_decisions'] as List).cast<String>())
                Card(
                  child: ListTile(
                    key: Key('decision-$d'),
                    title: Text(decisionLabels[d] ?? d),
                    subtitle: Text(decisionHelp[d] ?? ''),
                    onTap: () => _resolve(c, d, notes.text),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conflictos de sincronización')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_notice != null) Card(key: const Key('conflict-notice'), child: Padding(padding: const EdgeInsets.all(12), child: Text(_notice!))),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_loaded && _rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No hay conflictos abiertos.')),
            for (final c in _rows)
              Card(
                key: Key('conflict-${c['id']}'),
                child: ListTile(
                  title: Text('${conflictLabels[c['conflict_type']] ?? c['conflict_type']} · '
                      '${operationLabels[(c['operation'] as Map)['operation_type']] ?? ''}'),
                  subtitle: Text('${c['branch_name'] ?? '—'} · ${(c['operation'] as Map)['user_name'] ?? '—'} · ${dateTime(c['created_at'] as String?)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(c),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
