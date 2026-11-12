import 'package:fashionstore_movil/main.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:fashionstore_movil/offline/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Map<String, dynamic> sale(int n) => {
      'customer_id': null,
      'items': [{'product_variant_id': 11, 'quantity': n, 'unit_price': 120.0}],
      'payment': {'method': 'CASH', 'amount_received': null},
      'tax_id': null,
      'tax_name': null,
    };

Future<QueuedOperation> enqueue(AppServices s, Map<String, dynamic> payload, [String type = 'SALE']) =>
    s.queue.enqueue(type: type, branchId: 1, userId: 20, payload: payload, summary: 's');

List ids(Call c) => [for (final o in (c.body as Map)['operations'] as List) o['client_operation_id']];

void main() {
  late FakeBackend backend;
  late AppServices s;

  setUp(() async {
    backend = FakeBackend();
    s = await makeServices(backend, online: false); // se encola sin enviar
    await signIn(backend, s.auth);
  });

  test('sincroniza en orden FIFO y guarda el resultado de cada operacion (RN-08, RN-17)', () async {
    final a = await enqueue(s, sale(1));
    final b = await enqueue(s, sale(2));
    final c = await enqueue(s, {'customer_id': 40, 'items': []}, 'RESERVATION');
    s.connectivity.setOnline(true);
    backend.on('POST /sync/operations', (call) => json({
          'server_time': '',
          'results': [
            {'client_operation_id': a.clientOperationId, 'status': 'CONFIRMED', 'resource_code': 'V-000010'},
            {'client_operation_id': b.clientOperationId, 'status': 'IN_CONFLICT', 'conflict_type': 'STOCK', 'conflict_id': 3},
            {'client_operation_id': c.clientOperationId, 'status': 'REJECTED', 'reason_code': 'SUBSCRIPTION_NOT_CURRENT'},
          ],
        }));

    final summary = await s.sync.sync();
    final call = backend.callsTo('POST /sync/operations').single;
    final body = call.body as Map;
    expect([for (final o in body['operations'] as List) o['local_seq']], [1, 2, 3]);
    expect((body['operations'] as List).first, a.toSync());
    expect(body['device_id'], startsWith('android-'));
    expect((summary!.sent, summary.confirmed, summary.conflicts, summary.rejected), (3, 1, 1, 1));

    final ops = await s.queue.all();
    expect(ops.map((o) => o.status), [OpStatus.confirmed, OpStatus.inConflict, OpStatus.rejected]);
    expect(ops.first.result?['resource_code'], 'V-000010');
    expect(s.queue.pending, 0);
    // lo confirmado no se vuelve a enviar
    expect(await s.sync.sync(force: true), isNull);
  });

  test('error de red: queda para reintentar con espera creciente y se reenvia con el mismo UUID (RN-09, RN-23)', () async {
    final a = await enqueue(s, sale(1));
    s.connectivity.setOnline(true);
    backend.offline = true;
    await s.sync.sync();
    var op = (await s.queue.all()).single;
    expect(op.status, OpStatus.error);
    expect(op.attempts, 1);
    expect(op.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch));

    backend.offline = false;
    expect(await s.sync.sync(), isNull); // todavia no le toca
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [{'client_operation_id': a.clientOperationId, 'status': 'CONFIRMED', 'duplicate': true}],
        }));
    await s.sync.sync(force: true);
    expect(ids(backend.callsTo('POST /sync/operations').single), [a.clientOperationId]);
    op = (await s.queue.all()).single;
    expect(op.status, OpStatus.confirmed);
    expect(op.result?['duplicate'], isTrue);
  });

  test('no adelanta operaciones posteriores a una que espera reintento (FIFO)', () async {
    final a = await enqueue(s, sale(1));
    await enqueue(s, sale(2));
    await s.queue.saveAll([a.copyWith(status: OpStatus.error, attempts: 1, nextAttemptAt: DateTime.now().millisecondsSinceEpoch + 60000)]);
    s.connectivity.setOnline(true);
    expect(await s.sync.sync(), isNull);
    expect(backend.callsTo('POST /sync/operations'), isEmpty);
  });

  test('un resultado ERROR del servidor tambien se reintenta', () async {
    final a = await enqueue(s, sale(1));
    s.connectivity.setOnline(true);
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [{'client_operation_id': a.clientOperationId, 'status': 'ERROR', 'reason_code': 'INTERNAL_ERROR', 'message': 'Error temporal'}],
        }));
    await s.sync.sync();
    final op = (await s.queue.all()).single;
    expect((op.status, op.lastError), (OpStatus.error, 'Error temporal'));
  });

  test('envia lotes de hasta 100', () async {
    for (var i = 0; i < 101; i++) {
      await enqueue(s, sale(1));
    }
    s.connectivity.setOnline(true);
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [for (final id in ids(c)) {'client_operation_id': id, 'status': 'CONFIRMED'}],
        }));
    final summary = await s.sync.sync(force: true);
    final calls = backend.callsTo('POST /sync/operations');
    expect(calls.map((c) => ids(c).length), [100, 1]);
    expect(summary!.confirmed, 101);
  });

  test('actualiza conflictos resueltos y reenvia lo que el servidor no conoce (CU62)', () async {
    final a = await enqueue(s, sale(1));
    final b = await enqueue(s, sale(1));
    await s.queue.saveAll([a.copyWith(status: OpStatus.inConflict), b.copyWith(status: OpStatus.inConflict)]);
    s.connectivity.setOnline(true);
    backend.on('POST /sync/operations/status', (c) => json([
          {'client_operation_id': a.clientOperationId, 'status': 'CONFIRMED', 'resource_code': 'V-000011'},
          {'client_operation_id': b.clientOperationId, 'status': 'NOT_FOUND'},
        ]));
    await s.sync.refreshStatuses();
    expect(((backend.callsTo('POST /sync/operations/status').single.body as Map)['client_operation_ids'] as List).length, 2);
    final ops = await s.queue.all();
    expect(ops.map((o) => o.status), [OpStatus.confirmed, OpStatus.local]);
    expect(ops.first.result?['resource_code'], 'V-000011');
  });

  test('al volver la conexion sincroniza solo', () async {
    final a = await enqueue(s, sale(1));
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [{'client_operation_id': a.clientOperationId, 'status': 'CONFIRMED'}],
        }));
    s.sync.start();
    await pumpEventQueue();
    expect(backend.callsTo('POST /sync/operations'), isEmpty); // sin conexion
    s.connectivity.setOnline(true);
    await pumpEventQueue(times: 50);
    expect(backend.callsTo('POST /sync/operations').length, 1);
    expect((await s.queue.all()).single.status, OpStatus.confirmed);
    s.sync.stop();
  });

  test('sin permiso de sincronizar no envia', () async {
    final other = await makeServices(backend);
    await signIn(backend, other.auth, userJson(permissions: ['catalog.view']));
    await other.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: sale(1), summary: 's');
    expect(await other.sync.sync(force: true), isNull);
  });

  test('retryDelayMs crece y tiene tope', () {
    expect([1, 2, 3, 4].map(retryDelayMs), [5000, 10000, 20000, 40000]);
    expect(retryDelayMs(20), 300000);
  });
}
