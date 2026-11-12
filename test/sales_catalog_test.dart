import 'package:fashionstore_movil/app.dart';
import 'package:fashionstore_movil/main.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

/// Catalogo visual del cajero: Comprar -> carrito -> se corta internet -> pago al contado ->
/// vuelve internet -> la venta se sincroniza (preguntas 4 y 5).
void main() {
  late FakeBackend backend;

  setUpAll(() => initializeDateFormatting('es_BO'));
  setUp(() => backend = FakeBackend());

  Future<AppServices> openCatalog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    backend.on('POST /sync/operations', (_) => json({'server_time': '', 'results': []}));
    await tester.pumpWidget(s.provide(const FashionStoreApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catálogo'));
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('catalogo sin imagen, Comprar lleva al carrito y se cobra al contado sin internet', (tester) async {
    final s = await openCatalog(tester);
    // el producto no tiene imagen: se muestra igual con sus iniciales, precio y stock de la sucursal
    expect(find.text('CAMISA OXFORD'), findsOneWidget);
    expect(find.text('CO'), findsOneWidget);
    expect(find.textContaining('Bs 120,00'), findsOneWidget);
    expect(find.text('7 disp.'), findsOneWidget);
    expect(backend.callsTo('GET /offline/catalog').length, greaterThanOrEqualTo(2)); // al entrar y al abrir el catalogo

    await tester.tap(find.byKey(const Key('catalog-product-1')));
    await tester.pumpAndSettle();
    expect(find.text('DISPONIBLE'), findsOneWidget);

    // sin talla no deja comprar
    await tester.tap(find.byKey(const Key('buy')));
    await tester.pumpAndSettle();
    expect(find.text('Por favor seleccione su talla'), findsOneWidget);

    await tester.tap(find.byKey(const Key('product-size-L')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bs 130,00', findRichText: true), findsOneWidget);
    expect(find.text('SKU CAM-OX-L-NEG'), findsOneWidget);
    expect(find.text('2 disponibles en esta sucursal'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qty-up')));
    await tester.tap(find.byKey(const Key('qty-up')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    await tester.pumpAndSettle();
    expect(find.text('Solo hay 2 disponibles en esta sucursal.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qty-down')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    await tester.pumpAndSettle();

    // Comprar -> carrito y cobro
    expect(find.text('Carrito y cobro'), findsOneWidget);
    expect(find.byKey(const Key('line-12')), findsOneWidget);
    expect(find.text('Total Bs 260,00'), findsOneWidget);

    // se corta internet: el carrito sigue y se paga al contado
    backend.offline = true;
    s.connectivity.setOnline(false);
    await tester.pumpAndSettle();
    expect(find.text('Pagar al contado (sin conexión)'), findsOneWidget);
    expect(find.byKey(const Key('line-12')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Venta guardada sin conexión'), findsOneWidget);
    expect(find.text('Comprobante de venta PROV-000001'), findsOneWidget);
    final op = (await tester.runAsync(() => s.queue.all()))!.single;
    expect(op.status, OpStatus.local);
    expect(op.payload['payment'], {'method': 'CASH', 'amount_received': null});
    expect(s.saleCart.lines, isEmpty);

    // vuelve internet: se envia sola y el servidor la confirma
    backend.on('POST /sync/operations', (c) => json({
          'server_time': '',
          'results': [
            {'client_operation_id': op.clientOperationId, 'status': 'CONFIRMED', 'resource_code': 'V-000031'},
          ],
        }));
    backend.offline = false;
    await tester.runAsync(() async {
      s.connectivity.setOnline(true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final sent = backend.callsTo('POST /sync/operations').last.body as Map;
    expect((sent['operations'] as List).single['client_operation_id'], op.clientOperationId);
    final after = (await tester.runAsync(() => s.queue.all()))!.single;
    expect(after.status, OpStatus.confirmed);
    expect(after.result?['resource_code'], 'V-000031');
    s.sync.stop();
  });

  testWidgets('el stock del catalogo baja con la venta sin conexion (la ultima unidad queda agotada)', (tester) async {
    final s = await openCatalog(tester);
    backend.offline = true;
    s.connectivity.setOnline(false);
    await tester.pumpAndSettle();
    await tester.runAsync(() => s.catalog.adjustStock(1, 11, -5));
    await tester.runAsync(() => s.catalog.adjustStock(1, 12, -2));
    await tester.tap(find.byKey(const Key('sale-cart')));
    await tester.pumpAndSettle();
    expect(find.text('Carrito y cobro'), findsOneWidget);
    Navigator.of(tester.element(find.text('Carrito y cobro'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Agotado'), findsOneWidget);
    s.sync.stop();
  });
}
