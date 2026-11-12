import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../core/api_client.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import 'operation_queue.dart';

const _batch = 100;
const _baseDelayMs = 5000;
const _maxDelayMs = 5 * 60 * 1000;

/// Espera antes del siguiente intento: 5 s, 10 s, 20 s... hasta 5 min (RN-23).
int retryDelayMs(int attempts) => min(_maxDelayMs, _baseDelayMs * pow(2, max(0, attempts - 1)).toInt());

class SyncSummary {
  int sent = 0, confirmed = 0, rejected = 0, conflicts = 0, errors = 0;
}

/// Envia la cola al backend (CU61) y consulta el estado de lo pendiente (CU60, CU62).
/// - FIFO por local_seq (RN-17); no adelanta operaciones que esperan reintento.
/// - Reenviar es seguro: el servidor reconoce el UUID (RN-09) y devuelve el mismo resultado.
/// - Nada se borra por haberse enviado (RN-08): el resultado queda guardado en la operacion.
/// - Se dispara al abrir, al volver la conexion, cada 30 s si hay reintentos y a mano.
class SyncService extends ChangeNotifier {
  SyncService(this.api, this.auth, this.connectivity, this.queue,
      {DateTime Function()? clock, this.interval = const Duration(seconds: 30)})
      : _now = clock ?? DateTime.now;

  /// Cada cuanto se revisan los reintentos (null: sin temporizador, para las pruebas).
  final Duration? interval;

  final ApiClient api;
  final AuthService auth;
  final ConnectivityService connectivity;
  final OperationQueue queue;
  final DateTime Function() _now;

  bool syncing = false;
  DateTime? lastRunAt;
  SyncSummary? lastSummary;
  String? lastError;

  Timer? _timer;
  bool _wasOnline = true;
  bool _started = false;

  bool get _allowed => auth.isAuthenticated && auth.hasPermissions(['sync.run']);

  void start() {
    if (_started) return;
    _started = true;
    _wasOnline = connectivity.online;
    connectivity.addListener(_onConnectivity);
    queue.onEnqueued = () {
      if (connectivity.online) unawaited(sync());
    };
    if (interval != null) _timer = Timer.periodic(interval!, (_) => unawaited(sync()));
    unawaited(sync().then((_) => refreshStatuses()));
  }

  void _onConnectivity() {
    final online = connectivity.online;
    if (online && !_wasOnline) unawaited(sync().then((_) => refreshStatuses()));
    _wasOnline = online;
  }

  Future<SyncSummary?> sync({bool force = false}) async {
    if (syncing || !connectivity.online || !_allowed) return null;
    final now = _now().millisecondsSinceEpoch;
    final due = <QueuedOperation>[];
    for (final op in await queue.all()) {
      if (!OpStatus.outbox.contains(op.status)) continue;
      if (!force && op.nextAttemptAt > now) break; // FIFO: no adelantar a la que espera
      due.add(op);
    }
    if (due.isEmpty) return null;

    syncing = true;
    lastError = null;
    notifyListeners();
    final summary = SyncSummary();
    try {
      for (var i = 0; i < due.length; i += _batch) {
        final chunk = due.sublist(i, min(i + _batch, due.length));
        await queue.saveAll(chunk.map((o) => o.copyWith(status: OpStatus.sent)));
        try {
          final res = await api.post('/sync/operations', body: {
            'device_id': await _deviceId(),
            'operations': [for (final o in chunk) o.toSync()],
          }) as Map<String, dynamic>;
          summary.sent += chunk.length;
          await _apply(chunk, (res['results'] as List).cast<Map<String, dynamic>>(), summary);
        } on ApiError catch (e) {
          // el servidor pudo o no procesar el lote: reenviar es seguro por el UUID
          lastError = e.message;
          summary.errors += chunk.length;
          await queue.saveAll(chunk.map((o) => _failed(o, e.message)));
          if (e.isNetwork || e.status == 401 || e.status == 403) break;
        }
      }
    } finally {
      syncing = false;
      lastRunAt = _now();
      lastSummary = summary;
      await queue.refresh();
      notifyListeners();
    }
    return summary;
  }

  /// Conflictos que el encargado ya resolvio pasan a confirmados o cancelados; una operacion
  /// que el servidor no conoce vuelve a LOCAL para reenviarse.
  Future<void> refreshStatuses() async {
    if (!connectivity.online || !_allowed) return;
    final watch = (await queue.all()).where((o) => o.status == OpStatus.inConflict).take(200).toList();
    if (watch.isEmpty) return;
    try {
      final results = await api.post('/sync/operations/status', body: {
        'client_operation_ids': [for (final o in watch) o.clientOperationId],
      }) as List;
      final byId = {for (final r in results.cast<Map<String, dynamic>>()) r['client_operation_id'] as String: r};
      await queue.saveAll([
        for (final o in watch)
          if (byId[o.clientOperationId] case final r?)
            r['status'] == 'NOT_FOUND'
                ? o.copyWith(status: OpStatus.local, nextAttemptAt: 0)
                : o.copyWith(status: r['status'] as String, result: {...?o.result, ...r}),
      ]);
      await queue.refresh();
    } on ApiError {
      // se intentara en la proxima sincronizacion
    }
  }

  Future<void> _apply(List<QueuedOperation> chunk, List<Map<String, dynamic>> results, SyncSummary summary) async {
    final byId = {for (final r in results) r['client_operation_id'] as String: r};
    await queue.saveAll([
      for (final op in chunk)
        switch (byId[op.clientOperationId]) {
          null => (() {
              summary.errors++;
              return _failed(op, 'Sin respuesta del servidor para esta operación');
            })(),
          final r when r['status'] == 'ERROR' || r['status'] == 'NOT_FOUND' => (() {
              summary.errors++;
              return _failed(op, (r['message'] as String?) ?? 'Error temporal del servidor');
            })(),
          final r => (() {
              switch (r['status']) {
                case 'CONFIRMED':
                  summary.confirmed++;
                case 'REJECTED':
                  summary.rejected++;
                case 'IN_CONFLICT':
                  summary.conflicts++;
              }
              return op.copyWith(status: r['status'] as String, result: r, clearError: true);
            })(),
        },
    ]);
  }

  QueuedOperation _failed(QueuedOperation op, String message) {
    final attempts = op.attempts + 1;
    return op.copyWith(
      status: OpStatus.error,
      attempts: attempts,
      nextAttemptAt: _now().millisecondsSinceEpoch + retryDelayMs(attempts),
      lastError: message,
    );
  }

  Future<String> _deviceId() async {
    final db = queue.local.db;
    final rows = await db.query('meta', where: 'key = ?', whereArgs: ['device_id']);
    if (rows.isNotEmpty) return jsonDecode(rows.first['value'] as String) as String;
    final id = 'android-${const Uuid().v4()}';
    await db.insert('meta', {'key': 'device_id', 'value': jsonEncode(id)}, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  }

  /// Al cerrar sesion se detienen los disparadores automaticos.
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) connectivity.removeListener(_onConnectivity);
    queue.onEnqueued = null;
    _started = false;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
