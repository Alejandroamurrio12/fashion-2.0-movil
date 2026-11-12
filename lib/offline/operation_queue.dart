import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'local_db.dart';

/// Estados en el dispositivo (seccion 5.1, RN-16). ERROR = fallo temporal, se reintenta.
abstract final class OpStatus {
  static const local = 'LOCAL';
  static const sent = 'SENT';
  static const confirmed = 'CONFIRMED';
  static const rejected = 'REJECTED';
  static const inConflict = 'IN_CONFLICT';
  static const cancelled = 'CANCELLED';
  static const error = 'ERROR';

  /// Todavia deben enviarse o reenviarse.
  static const outbox = {local, sent, error};
}

/// Operacion registrada en el dispositivo. Nunca se borra por haberse enviado (RN-08).
class QueuedOperation {
  QueuedOperation({
    required this.clientOperationId,
    required this.localSeq,
    required this.operationType,
    required this.branchId,
    required this.registeredAt,
    required this.payload,
    required this.status,
    required this.attempts,
    required this.nextAttemptAt,
    required this.userId,
    required this.summary,
    required this.provisionalCode,
    this.result,
    this.lastError,
    required this.updatedAt,
  });

  final String clientOperationId;
  final int localSeq;
  final String operationType;
  final int branchId;
  final String registeredAt;
  final Map<String, dynamic> payload;
  final String status;
  final int attempts;
  final int nextAttemptAt;
  final int userId;
  final String summary;
  final String provisionalCode;
  final Map<String, dynamic>? result;
  final String? lastError;
  final String updatedAt;

  factory QueuedOperation.fromRow(Map<String, Object?> r) => QueuedOperation(
        clientOperationId: r['client_operation_id'] as String,
        localSeq: r['local_seq'] as int,
        operationType: r['operation_type'] as String,
        branchId: r['branch_id'] as int,
        registeredAt: r['registered_at'] as String,
        payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
        status: r['status'] as String,
        attempts: r['attempts'] as int,
        nextAttemptAt: r['next_attempt_at'] as int,
        userId: r['user_id'] as int,
        summary: r['summary'] as String,
        provisionalCode: r['provisional_code'] as String,
        result: r['result'] == null ? null : jsonDecode(r['result'] as String) as Map<String, dynamic>,
        lastError: r['last_error'] as String?,
        updatedAt: r['updated_at'] as String,
      );

  Map<String, Object?> toRow() => {
        'client_operation_id': clientOperationId,
        'local_seq': localSeq,
        'operation_type': operationType,
        'branch_id': branchId,
        'registered_at': registeredAt,
        'payload': jsonEncode(payload),
        'status': status,
        'attempts': attempts,
        'next_attempt_at': nextAttemptAt,
        'user_id': userId,
        'summary': summary,
        'provisional_code': provisionalCode,
        'result': result == null ? null : jsonEncode(result),
        'last_error': lastError,
        'updated_at': updatedAt,
      };

  /// Lo que se envia al backend (SyncOperationIn).
  Map<String, dynamic> toSync() => {
        'client_operation_id': clientOperationId,
        'local_seq': localSeq,
        'operation_type': operationType,
        'branch_id': branchId,
        'registered_at': registeredAt,
        'payload': payload,
      };

  QueuedOperation copyWith({
    String? status,
    int? attempts,
    int? nextAttemptAt,
    Map<String, dynamic>? result,
    String? lastError,
    bool clearError = false,
  }) =>
      QueuedOperation(
        clientOperationId: clientOperationId,
        localSeq: localSeq,
        operationType: operationType,
        branchId: branchId,
        registeredAt: registeredAt,
        payload: payload,
        status: status ?? this.status,
        attempts: attempts ?? this.attempts,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        userId: userId,
        summary: summary,
        provisionalCode: provisionalCode,
        result: result ?? this.result,
        lastError: clearError ? null : (lastError ?? this.lastError),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
}

/// Cola local de operaciones sin conexion: cada una con UUID v4 (idempotencia, RN-09) y
/// local_seq creciente (orden FIFO, RN-17). El envio al servidor lo hace SyncService (M4).
class OperationQueue extends ChangeNotifier {
  OperationQueue(this.local);

  final LocalDb local;
  static const _uuid = Uuid();

  List<QueuedOperation> operations = const [];

  int get pending => operations.where((o) => OpStatus.outbox.contains(o.status)).length;
  int get conflicts => operations.where((o) => o.status == OpStatus.inConflict).length;
  int get rejected => operations.where((o) => o.status == OpStatus.rejected).length;

  /// Se llama despues de encolar (SyncService la usa para intentar enviar enseguida).
  void Function()? onEnqueued;

  Future<void> refresh() async {
    final rows = await local.db.query('operations', orderBy: 'local_seq');
    operations = [for (final r in rows) QueuedOperation.fromRow(r)];
    notifyListeners();
  }

  Future<QueuedOperation> enqueue({
    required String type,
    required int branchId,
    required int userId,
    required Map<String, dynamic> payload,
    required String summary,
  }) async {
    final op = await local.db.transaction((tx) async {
      final seqRow = await tx.query('meta', where: 'key = ?', whereArgs: ['local_seq']);
      final seq = (seqRow.isEmpty ? 0 : int.parse(seqRow.first['value'] as String)) + 1;
      await tx.insert('meta', {'key': 'local_seq', 'value': '$seq'}, conflictAlgorithm: ConflictAlgorithm.replace);
      final now = DateTime.now().toUtc().toIso8601String();
      final op = QueuedOperation(
        clientOperationId: _uuid.v4(),
        localSeq: seq,
        operationType: type,
        branchId: branchId,
        registeredAt: now,
        payload: payload,
        status: OpStatus.local,
        attempts: 0,
        nextAttemptAt: 0,
        userId: userId,
        summary: summary,
        provisionalCode: 'PROV-${seq.toString().padLeft(6, '0')}',
        updatedAt: now,
      );
      await tx.insert('operations', op.toRow());
      return op;
    });
    await refresh();
    onEnqueued?.call();
    return op;
  }

  Future<void> saveAll(Iterable<QueuedOperation> ops) async {
    final batch = local.db.batch();
    for (final op in ops) {
      batch.insert('operations', op.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<QueuedOperation>> all() async =>
      [for (final r in await local.db.query('operations', orderBy: 'local_seq')) QueuedOperation.fromRow(r)];
}
