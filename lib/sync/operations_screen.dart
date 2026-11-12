import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import '../offline/operation_queue.dart';
import '../offline/sync_service.dart';
import '../ui/format.dart';

const statusLabels = {
  OpStatus.local: 'Pendiente',
  OpStatus.sent: 'Enviada',
  OpStatus.confirmed: 'Confirmada',
  OpStatus.rejected: 'Rechazada',
  OpStatus.inConflict: 'En conflicto',
  OpStatus.cancelled: 'Cancelada',
  OpStatus.error: 'Reintentando',
};

const operationLabels = {'SALE': 'Venta', 'RESERVATION': 'Reserva', 'EXCHANGE': 'Cambio'};

/// CU60 operaciones pendientes, CU61 sincronizar, CU62 resultado de cada operacion.
class OperationsScreen extends StatelessWidget {
  const OperationsScreen({super.key});

  /// Motivo legible: mensaje del servidor o error del ultimo envio.
  static String reason(QueuedOperation op) {
    if (op.status == OpStatus.error) return op.lastError ?? 'Error temporal';
    final r = op.result;
    if (r == null) return '';
    final code = r['reason_code'] as String?;
    return (code == null ? null : messageFor(code)) ?? (r['message'] as String?) ?? code ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<OperationQueue>();
    final sync = context.watch<SyncService>();
    final online = context.watch<ConnectivityService>().online;
    final userId = context.watch<AuthService>().me?.id;
    final ops = queue.operations.where((o) => o.userId == userId).toList().reversed.toList();
    final s = sync.lastSummary;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Operaciones sin conexión')),
      body: RefreshIndicator(
        onRefresh: () async {
          await sync.sync(force: true);
          await sync.refreshStatuses();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sin sincronizar: ${queue.pending} · en conflicto: ${queue.conflicts} · rechazadas: ${queue.rejected}',
                        key: const Key('counters')),
                    if (sync.lastRunAt != null)
                      Text('Última sincronización: ${dateTime(sync.lastRunAt!.toUtc().toIso8601String())}'
                          '${s == null ? '' : ' · enviadas ${s.sent}: ${s.confirmed} confirmadas, ${s.rejected} rechazadas, ${s.conflicts} en conflicto'}',
                          key: const Key('last-run')),
                    if (sync.lastError != null) Text(sync.lastError!, style: TextStyle(color: scheme.error)),
                    if (queue.conflicts > 0)
                      const Text('Los conflictos los resuelve el encargado o el administrador; el resultado se actualiza solo.'),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const Key('sync-now'),
                      onPressed: online && !sync.syncing
                          ? () async {
                              await sync.sync(force: true);
                              await sync.refreshStatuses();
                            }
                          : null,
                      icon: const Icon(Icons.sync),
                      label: Text(sync.syncing ? 'Sincronizando…' : (online ? 'Sincronizar ahora' : 'Sin conexión')),
                    ),
                  ],
                ),
              ),
            ),
            if (ops.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No hay operaciones guardadas en este teléfono.')),
            for (final op in ops)
              Card(
                key: Key('op-${op.localSeq}'),
                child: ListTile(
                  title: Text('${operationLabels[op.operationType] ?? op.operationType} ${op.provisionalCode} · ${op.summary}'),
                  subtitle: Text([
                    dateTime(op.registeredAt),
                    if (op.result?['resource_code'] != null) '${op.result!['resource_code']}',
                    if (reason(op).isNotEmpty) reason(op),
                  ].join(' · ')),
                  trailing: Chip(
                    label: Text(statusLabels[op.status] ?? op.status),
                    backgroundColor: switch (op.status) {
                      OpStatus.confirmed => scheme.primaryContainer,
                      OpStatus.rejected => scheme.errorContainer,
                      _ => scheme.tertiaryContainer,
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
