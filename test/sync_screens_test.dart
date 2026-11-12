import 'package:fashionstore_movil/app.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

Map<String, dynamic> conflict({String type = 'STOCK', List<String>? decisions}) => {
      'id': 3,
      'branch_id': 1,
      'branch_name': 'Centro',
      'conflict_type': type,
      'reason_code': type == 'STOCK' ? 'INSUFFICIENT_STOCK' : 'PRICE_CHANGED',
      'detail': {
        'lines': [
          type == 'STOCK'
              ? {'product_variant_id': 11, 'requested': 1, 'available': 0}
              : {'product_variant_id': 11, 'quantity': 1, 'charged_price': 120, 'current_price': 130},
        ],
      },
      'price_difference': type == 'PRICE' ? -10 : null,
      'status': 'OPEN',
      'decision': null,
      'decision_notes': null,
      'resolved_by': null,
      'resolved_at': null,
      'created_at': '2026-11-11T12:00:00Z',
      'allowed_decisions': decisions ?? ['ACCEPT_PARTIAL', 'ADJUST_INVENTORY', 'CANCEL'],
      'operation': {
        'client_operation_id': 'b2',
        'operation_type': 'SALE',
        'status': 'IN_CONFLICT',
        'user_id': 21,
        'user_name': 'Beto Caja',
        'registered_at': '2026-11-11T11:00:00Z',
        'resource_code': null,
        'payload': {},
      },
    };

void main() {
  late FakeBackend backend;

  setUpAll(() => initializeDateFormatting('es_BO'));
  setUp(() => backend = FakeBackend());

  testWidgets('operaciones: estado y resultado de cada una; sincronizar ahora', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    final a = await s.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: {'items': []}, summary: '2 prendas · Bs 240,00');
    final b = await s.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: {'items': []}, summary: '1 prenda · Bs 130,00');
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [
            {'client_operation_id': a.clientOperationId, 'status': 'CONFIRMED', 'resource_code': 'V-000020'},
            {'client_operation_id': b.clientOperationId, 'status': 'REJECTED', 'reason_code': 'OFFLINE_PAYMENT_NOT_CASH'},
          ],
        }));
    await tester.pumpWidget(s.provide(const FashionStoreApp()));
    await tester.pumpAndSettle();
    // al entrar ya se sincronizo (start) -> el contador del inicio no muestra pendientes
    expect(backend.callsTo('POST /sync/operations').length, 1);
    await tester.tap(find.text('Operaciones sin conexión'));
    await tester.pumpAndSettle();
    expect(find.textContaining('V-000020'), findsOneWidget);
    expect(find.text('Confirmada'), findsOneWidget);
    expect(find.text('Rechazada'), findsOneWidget);
    expect(find.textContaining('Sin conexión solo se aceptan ventas al contado en efectivo.'), findsOneWidget);
    expect(find.textContaining('Sin sincronizar: 0'), findsOneWidget);
    s.sync.stop();
  });

  testWidgets('conflictos: el encargado ve el detalle y resuelve con una decision permitida (CU63)', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth, userJson(id: 30, role: 'ENCARGADO', permissions: ['sync.resolve_conflicts', 'inventory.view']));
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /sync/conflicts', (_) => json([conflict()]));
    backend.on('POST /sync/conflicts/3/resolve', (_) => json({...conflict(), 'status': 'RESOLVED', 'decision': 'CANCEL'}));
    await tester.pumpWidget(s.provide(const FashionStoreApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conflictos de sincronización'));
    await tester.pumpAndSettle();
    expect(backend.callsTo('GET /sync/conflicts').single.query, {'status': 'OPEN'});
    await tester.tap(find.byKey(const Key('conflict-3')));
    await tester.pumpAndSettle();
    expect(find.text('Variante #11: pedidas 1, disponibles 0'), findsOneWidget);
    expect(find.text('Aceptar lo disponible'), findsOneWidget);
    expect(find.text('Aceptar el precio cobrado'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Ya no había stock');
    await tester.tap(find.byKey(const Key('decision-CANCEL')));
    await tester.pumpAndSettle();
    expect(backend.callsTo('POST /sync/conflicts/3/resolve').single.body, {'decision': 'CANCEL', 'notes': 'Ya no había stock'});
    expect(find.text('Conflicto #3 resuelto: Cancelar la operación.'), findsOneWidget);
    expect(find.text('No hay conflictos abiertos.'), findsOneWidget);
  });

  testWidgets('conflicto de precio muestra cobrado contra vigente y solo ACCEPT_PRICE', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth, userJson(id: 30, role: 'ENCARGADO', permissions: ['sync.resolve_conflicts']));
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /sync/conflicts', (_) => json([conflict(type: 'PRICE', decisions: ['ACCEPT_PRICE'])]));
    await tester.pumpWidget(s.provide(const FashionStoreApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conflictos de sincronización'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conflict-3')));
    await tester.pumpAndSettle();
    expect(find.text('Variante #11: 1 u. cobradas a Bs 120,00, vigente Bs 130,00'), findsOneWidget);
    expect(find.byKey(const Key('decision-ACCEPT_PRICE')), findsOneWidget);
    expect(find.byKey(const Key('decision-CANCEL')), findsNothing);
  });

  testWidgets('el cajero no ve conflictos; ve operaciones si tiene el plan offline', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    await tester.pumpWidget(s.provide(const FashionStoreApp()));
    await tester.pumpAndSettle();
    expect(find.text('Conflictos de sincronización'), findsNothing);
    expect(find.text('Operaciones sin conexión'), findsOneWidget);
    expect(OpStatus.outbox, contains(OpStatus.error));
    s.sync.stop();
  });
}
