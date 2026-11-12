import 'package:fashionstore_movil/offline/catalog_store.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());

  test('descarga el catalogo y lo consulta sin conexion (CU59)', () async {
    final s = await makeServices(backend);
    await signIn(backend, s.auth);
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    final info = await s.catalog.download();
    expect(info.products, 1);
    expect(s.catalog.info?.currency, 'BOB');

    expect((await s.catalog.search('oxford')).map((v) => v.label), ['Camisa Oxford M / Negro', 'Camisa Oxford L / Negro']);
    expect((await s.catalog.search('cam-ox-l')).single.sku, 'CAM-OX-L-NEG');
    expect(await s.catalog.search('x'), isEmpty);
    expect(await s.catalog.available(1, 11), 5);
    expect(await s.catalog.available(2, 11), 0);
    expect((await s.catalog.variant(12))?.price, 130);
    expect((await s.catalog.branches()).map((b) => b.name), ['Centro', 'Sur']);
    expect((await s.catalog.searchCustomers('1234')).single.fullName, 'Luis Cliente');
  });

  test('una nueva descarga reemplaza el catalogo anterior', () async {
    final s = await makeServices(backend);
    final catalog = catalogJson();
    await s.catalog.save(catalog);
    (catalog['products'] as List).clear();
    await s.catalog.save(catalog);
    expect(await s.catalog.search('oxford'), isEmpty);
    expect(s.catalog.info?.products, 0);
  });

  test('descuenta el stock local sin bajar de cero', () async {
    final s = await makeServices(backend);
    await s.catalog.save(catalogJson());
    await s.catalog.adjustStock(1, 11, -3);
    expect(await s.catalog.available(1, 11), 2);
    await s.catalog.adjustStock(1, 11, -10);
    expect(await s.catalog.available(1, 11), 0);
    await s.catalog.adjustStock(2, 12, 1);
    expect(await s.catalog.available(2, 12), 1);
  });

  test('marca el catalogo desactualizado segun la antiguedad maxima', () async {
    final s = await makeServices(backend);
    await s.catalog.save(catalogJson(generatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 25))));
    expect(s.catalog.stale, isTrue);
    await s.catalog.save(catalogJson());
    expect(s.catalog.stale, isFalse);
  });

  test('si entra otro usuario u otra empresa borra los datos locales (RN-22)', () async {
    final s = await makeServices(backend);
    await s.catalog.ensureOwner(20, 1);
    await s.catalog.save(catalogJson());
    await s.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: {}, summary: 'a');
    await s.catalog.ensureOwner(20, 1);
    expect(s.catalog.info, isNotNull);

    await s.catalog.ensureOwner(21, 1);
    expect(s.catalog.info, isNull);
    expect(await s.queue.all(), isEmpty);

    await s.catalog.save(catalogJson());
    await s.catalog.ensureOwner(21, 2);
    expect(await s.catalog.search('oxford'), isEmpty);
  });

  test('la cola numera en orden, con UUID, estado LOCAL y codigo provisional (RN-09, RN-17)', () async {
    final s = await makeServices(backend);
    final a = await s.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: {'x': 1}, summary: 'a');
    final b = await s.queue.enqueue(type: 'RESERVATION', branchId: 1, userId: 20, payload: {'y': 2}, summary: 'b');
    expect([a.localSeq, b.localSeq], [1, 2]);
    expect(a.clientOperationId, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(a.clientOperationId, isNot(b.clientOperationId));
    expect(a.status, OpStatus.local);
    expect(b.provisionalCode, 'PROV-000002');
    expect(s.queue.pending, 2);

    // persiste (otra instancia de la cola sobre la misma base la ve)
    final again = OperationQueue(s.queue.local);
    await again.refresh();
    expect(again.operations.map((o) => o.payload), [{'x': 1}, {'y': 2}]);
    expect(again.operations.first.toSync().keys, ['client_operation_id', 'local_seq', 'operation_type', 'branch_id', 'registered_at', 'payload']);
  });

  test('sin catalogo no hay info y el bootstrap no descarga si no puede operar offline', () async {
    final s = await makeServices(backend);
    await signIn(backend, s.auth, userJson(permissions: ['catalog.view']));
    await s.bootstrap.init();
    expect(backend.callsTo('GET /offline/catalog'), isEmpty);
    expect(s.catalog.info, isNull);
    expect(s.catalog, isA<CatalogStore>());
  });
}
