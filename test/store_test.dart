import 'package:fashionstore_movil/app.dart';
import 'package:fashionstore_movil/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

Widget appOf(AppServices s) => s.provide(const FashionStoreApp());

final customer = userJson(id: 30, role: 'CLIENTE', permissions: const ['catalog.view', 'reservations.own']);

Map<String, dynamic> storeJson({bool canReserve = true}) => {
      'tenant_name': 'Moda Andina S.R.L.',
      'currency': 'Bs',
      'reservation_hours': 48,
      'can_reserve': canReserve,
      'branches': [
        {'id': 1, 'name': 'Centro', 'city': 'La Paz', 'address': null},
        {'id': 2, 'name': 'Sur', 'city': 'La Paz', 'address': null},
      ],
      'categories': [
        {'id': 1, 'name': 'Camisas', 'product_count': 1},
        {'id': 2, 'name': 'Pantalones', 'product_count': 1},
      ],
      'colors': [
        {'name': 'Negro', 'hex_code': '#000000'},
      ],
      'products': [
        {
          'id': 1, 'code': 'CAM-OX', 'name': 'Camisa Oxford', 'description': 'Algodón', 'brand': 'Andina',
          'category_id': 1, 'category': 'Camisas', 'cover_image_url': null, 'min_price': 120, 'max_price': 135,
          'is_new': true, 'created_at': '2026-11-10T10:00:00Z', 'available': 6,
          'variants': [
            {'id': 11, 'sku': 'M', 'size': 'M', 'color': 'Negro', 'hex_code': '#000000', 'price': 120, 'available': 5,
             'availability': [{'branch_id': 1, 'available': 5}]},
            {'id': 12, 'sku': 'L', 'size': 'L', 'color': 'Negro', 'hex_code': '#000000', 'price': 135, 'available': 1,
             'availability': [{'branch_id': 2, 'available': 1}]},
          ],
        },
        {
          'id': 2, 'code': 'JEAN', 'name': 'Jean Slim', 'description': null, 'brand': null,
          'category_id': 2, 'category': 'Pantalones', 'cover_image_url': null, 'min_price': 200, 'max_price': 200,
          'is_new': false, 'created_at': '2026-09-01T10:00:00Z', 'available': 0,
          'variants': [
            {'id': 21, 'sku': 'J', 'size': '32', 'color': 'Negro', 'hex_code': '#000000', 'price': 200, 'available': 0, 'availability': []},
          ],
        },
      ],
    };

void main() {
  late FakeBackend backend;

  setUpAll(() => initializeDateFormatting('es_BO'));
  setUp(() => backend = FakeBackend());

  Future<AppServices> openStore(WidgetTester tester, {bool canReserve = true}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth, customer);
    backend.on('GET /store/catalog', (_) => json(storeJson(canReserve: canReserve)));
    await tester.pumpWidget(appOf(s));
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('el cliente entra a la tienda: precios, etiquetas y filtros', (tester) async {
    await openStore(tester);
    expect(find.text('Moda Andina S.R.L.'), findsOneWidget);
    expect(find.text('CAMISA OXFORD'), findsOneWidget);
    expect(find.text('JEAN SLIM'), findsOneWidget);
    expect(find.text('Nuevo'), findsOneWidget);
    expect(find.text('Agotado'), findsOneWidget);
    expect(find.textContaining('Bs 120,00'), findsOneWidget);
    expect(find.text('2 artículos'), findsOneWidget);
    // el cliente no ve el punto de venta
    expect(find.text('Punto de venta'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('category-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-2')));
    await tester.pumpAndSettle();
    expect(find.text('CAMISA OXFORD'), findsNothing);
    expect(find.text('JEAN SLIM'), findsOneWidget);

    await tester.dragUntilVisible(find.text('Todas (2)'), find.byKey(const Key('category-2')), const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todas (2)'));
    await tester.tap(find.byKey(const Key('only-available')));
    await tester.pumpAndSettle();
    expect(find.text('JEAN SLIM'), findsNothing);

    await tester.tap(find.byKey(const Key('only-available')));
    await tester.enterText(find.byKey(const Key('store-search')), 'jean');
    await tester.pumpAndSettle();
    expect(find.text('JEAN SLIM'), findsOneWidget);
    expect(find.text('CAMISA OXFORD'), findsNothing);
  });

  testWidgets('detalle: elige talla, ve disponibilidad y agrega al carrito; reserva', (tester) async {
    final s = await openStore(tester);
    await tester.tap(find.byKey(const Key('product-1')));
    await tester.pumpAndSettle();
    expect(find.text('Bs 120,00'), findsWidgets);
    expect(find.text('5 disponibles'), findsOneWidget);
    expect(find.text('Centro: 5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('size-L')));
    await tester.pumpAndSettle();
    expect(find.text('1 disponibles'), findsOneWidget);
    expect(find.text('Sur: 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('size-M')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('2'), findsWidgets);
    await tester.tap(find.byKey(const Key('add-to-cart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('added')), findsOneWidget);
    expect(s.cart.count, 2);

    // cerrar la hoja y abrir el carrito
    Navigator.of(tester.element(find.byKey(const Key('added')))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cart-count')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cart-button')));
    await tester.pumpAndSettle();
    expect(find.text('Camisa Oxford'), findsOneWidget);
    expect(find.text('Bs 240,00'), findsWidgets);

    backend.on('POST /reservations', (call) => json({
          'id': 7, 'reservation_code': 'R-000007', 'customer_id': 30, 'customer_name': 'Luis', 'branch_id': 1,
          'status': 'CONFIRMED', 'notes': null, 'expires_at': '2026-11-14T10:00:00Z', 'completed_at': null,
          'cancelled_at': null, 'origin': 'ONLINE', 'client_operation_id': null, 'registered_at': null,
          'created_at': '2026-11-12T10:00:00Z', 'total_amount': 240, 'items': [],
        }, 201));
    await tester.tap(find.byKey(const Key('confirm-reservation')));
    await tester.pumpAndSettle();

    final body = backend.callsTo('POST /reservations').single.body as Map;
    expect(body['branch_id'], 1); // sucursal sugerida: la que tiene todo
    expect(body['customer_id'], isNull);
    expect(body['items'], [{'product_variant_id': 11, 'quantity': 2}]);
    expect(find.byKey(const Key('reservation-done')), findsOneWidget);
    expect(find.text('R-000007'), findsOneWidget);
    expect(s.cart.lines, isEmpty);
  });

  testWidgets('carrito: avisa falta de stock en la sucursal y muestra el rechazo del servidor', (tester) async {
    final s = await openStore(tester);
    final p = s.cart.catalog!.products.first;
    s.cart.add(p, p.variants.first, 3); // M: 5 en Centro, 0 en Sur
    await tester.tap(find.byKey(const Key('cart-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pickup-branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sur').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('short-11')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('confirm-reservation'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('pickup-branch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Centro').last);
    await tester.pumpAndSettle();
    backend.on('POST /reservations', (_) => apiError('INSUFFICIENT_STOCK', 409));
    await tester.tap(find.byKey(const Key('confirm-reservation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cart-error')), findsOneWidget);
    expect(s.cart.lines.length, 1); // el carrito no se pierde
    expect(backend.callsTo('GET /store/catalog').length, 2); // recarga la disponibilidad
  });

  testWidgets('sin reservas habilitadas no se puede agregar', (tester) async {
    await openStore(tester, canReserve: false);
    expect(find.textContaining('no tiene habilitadas las reservas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('product-1')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('add-to-cart'))).onPressed, isNull);
  });
}
