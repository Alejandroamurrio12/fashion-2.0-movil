import 'package:fashionstore_movil/app.dart';
import 'package:fashionstore_movil/main.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:fashionstore_movil/sales/pickers.dart';
import 'package:fashionstore_movil/sales/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

Map<String, dynamic> inventoryRow({int variantId = 11, int available = 5, double price = 120}) => {
      'product_variant_id': variantId,
      'sku': variantId == 11 ? 'CAM-OX-M-NEG' : 'CAM-OX-L-NEG',
      'product_name': 'Camisa Oxford',
      'size': variantId == 11 ? 'M' : 'L',
      'color': 'Negro',
      'price': price,
      'available_quantity': available,
    };

Map<String, dynamic> receiptJson({String code = 'CB-000050', bool provisional = false, double total = 240, double change = 60}) => {
      'receipt_code': code,
      'receipt_type': 'RECEIPT',
      'is_provisional': provisional,
      'reference': 'V-000050',
      'company': {'legal_name': 'Moda Andina S.R.L.', 'nit': '1000000011'},
      'branch': 'Centro',
      'issued_at': '2026-11-11T10:00:00Z',
      'issued_by': 'Carla Caja',
      'tax_id': null,
      'tax_name': null,
      'items': [
        {'description': 'Camisa Oxford M/Negro', 'sku': 'CAM-OX-M-NEG', 'quantity': 2, 'unit_price': 120, 'subtotal': 240},
      ],
      'total_amount': total,
      'payments': [
        {'payment_method': 'CASH', 'amount': total, 'amount_received': total + change, 'change_amount': change, 'external_reference': null},
      ],
    };

/// Abre la app con sesion de cajero y entra al punto de venta.
Future<AppServices> openPos(WidgetTester tester, FakeBackend backend, {bool online = true, bool catalog = true, Map<String, dynamic>? user}) async {
  // pantalla alta: el ListView construye solo lo visible y el boton de confirmar queda abajo
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = await servicesFor(tester, backend, online: online);
  await signIn(backend, s.auth, user);
  await s.bootstrap.init();
  if (catalog) await s.catalog.save(catalogJson());
  backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
  backend.on('GET /offline/catalog', (_) => json(catalogJson()));
  if (!online) backend.offline = true;
  await tester.pumpWidget(s.provide(const FashionStoreApp()));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Punto de venta'));
  await tester.pumpAndSettle();
  return s;
}

Future<void> addItem(WidgetTester tester, String label) async {
  await tester.enterText(find.byKey(const Key('search-Agregar prenda')), 'oxford');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(label).first);
  await tester.pumpAndSettle();
}

void main() {
  late FakeBackend backend;

  setUpAll(() => initializeDateFormatting('es_BO'));
  setUp(() => backend = FakeBackend());

  testWidgets('venta con conexion en efectivo: envia la venta y muestra el comprobante con el cambio', (tester) async {
    await openPos(tester, backend);
    backend.on('GET /inventory', (c) => json([inventoryRow(), inventoryRow(variantId: 12, available: 0, price: 130)]));
    await addItem(tester, 'M / Negro');
    expect(backend.callsTo('GET /inventory').last.query, {'branch_id': '1', 'q': 'oxford', 'limit': '50'});
    await tester.tap(find.byKey(const Key('plus-11')));
    await tester.pump();
    expect(find.text('Total Bs 240,00'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('received')), '300');
    await tester.pump();
    expect(find.text('Cambio: Bs 60,00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('taxId')), '1234567');

    backend.on('POST /sales', (_) => json({'id': 50, 'sale_code': 'V-000050'}, 201));
    backend.on('GET /sales/50/receipt', (_) => json(receiptJson()));
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();

    expect(backend.callsTo('POST /sales').single.body, {
      'branch_id': 1,
      'customer_id': null,
      'reservation_id': null,
      'items': [{'product_variant_id': 11, 'quantity': 2}],
      'payment': {'method': 'CASH', 'amount_received': 300.0, 'external_reference': null},
      'tax_id': '1234567',
      'tax_name': null,
    });
    expect(find.text('Venta registrada'), findsOneWidget);
    expect(find.text('Comprobante de venta CB-000050'), findsOneWidget);
    expect(find.text('Cambio a entregar: Bs 60,00'), findsOneWidget);
  });

  testWidgets('no deja vender mas de lo disponible y muestra el rechazo del servidor', (tester) async {
    await openPos(tester, backend);
    backend.on('GET /inventory', (c) => json([inventoryRow(available: 1)]));
    await addItem(tester, 'M / Negro');
    await tester.tap(find.byKey(const Key('plus-11')));
    await tester.pump();
    expect(find.textContaining('Solo hay 1 disponibles.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Revise las cantidades marcadas.'), findsOneWidget);
    expect(backend.callsTo('POST /sales'), isEmpty);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pump();
    backend.on('POST /sales', (_) => apiError('INSUFFICIENT_STOCK', 409, {'product_variant_id': 11, 'available': 0, 'requested': 1}));
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Existencia insuficiente: hay 0 disponibles y se solicitaron 1.'), findsOneWidget);
  });

  testWidgets('tarjeta con referencia', (tester) async {
    await openPos(tester, backend);
    backend.on('GET /inventory', (c) => json([inventoryRow()]));
    await addItem(tester, 'M / Negro');
    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tarjeta').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reference')), 'VCH-991');
    backend.on('POST /sales', (_) => json({'id': 51, 'sale_code': 'V-000051'}, 201));
    backend.on('GET /sales/51/receipt', (_) => json(receiptJson(total: 120, change: 0)));
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect((backend.callsTo('POST /sales').single.body as Map)['payment'], {'method': 'CARD', 'amount_received': null, 'external_reference': 'VCH-991'});
  });

  testWidgets('sin conexion: solo efectivo, cola local con precio cobrado y comprobante provisional (RN-06)', (tester) async {
    final s = await openPos(tester, backend, online: false);
    expect(find.byKey(const Key('offline-banner')), findsOneWidget);
    expect(find.text('Guardar venta sin conexión'), findsOneWidget);
    await addItem(tester, 'L / Negro');
    await tester.tap(find.byKey(const Key('plus-12')));
    await tester.pump();
    expect(find.text('Total Bs 260,00'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('confirm')));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Venta guardada sin conexión'), findsOneWidget);
    expect(find.text('Comprobante de venta PROV-000001'), findsOneWidget);
    expect(find.byKey(const Key('provisional')), findsOneWidget);
    expect(backend.calls.where((c) => c.path == '/sales'), isEmpty);

    final op = (await s.queue.all()).single;
    expect(op.operationType, 'SALE');
    expect(op.status, OpStatus.local);
    expect(op.branchId, 1);
    expect(op.payload, {
      'customer_id': null,
      'items': [{'product_variant_id': 12, 'quantity': 2, 'unit_price': 130.0}],
      'payment': {'method': 'CASH', 'amount_received': null},
      'tax_id': null,
      'tax_name': null,
    });
    expect(await s.catalog.available(1, 12), 0); // 2 - 2 en el stock local
  });

  testWidgets('sin conexion y sin catalogo no se puede vender', (tester) async {
    await openPos(tester, backend, online: false, catalog: false);
    // sin catalogo tampoco hay sucursales: no se muestra el formulario de venta
    expect(find.text('Sin conexión y sin catálogo descargado en este dispositivo: no se puede vender.'), findsOneWidget);
    expect(find.byKey(const Key('confirm')), findsNothing);
  });

  testWidgets('sin plan offline no se vende sin conexion', (tester) async {
    final base = userJson();
    final features = Map<String, bool>.from((base['subscription'] as Map)['features'] as Map)..['offline'] = false;
    await openPos(tester, backend, online: false, user: userJson(features: features));
    expect(find.text('Sin conexión: su rol o el plan de la empresa no permiten vender sin conexión.'), findsOneWidget);
  });

  test('CartLine valida cantidades', () {
    const item = PickedItem(variantId: 1, label: 'x', sku: 's', price: 10, available: 2);
    expect(CartLine(item, 3).problem, 'Solo hay 2 disponibles.');
    expect(CartLine(item, 0).problem, 'Cantidad entre 1 y 1000.');
    expect(CartLine(item, 2).problem, isNull);
  });
}
