import 'package:fashionstore_movil/app.dart';
import 'package:fashionstore_movil/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'helpers.dart';

Widget appOf(AppServices s) => s.provide(const FashionStoreApp());

void main() {
  late FakeBackend backend;

  setUpAll(() => initializeDateFormatting('es_BO'));
  setUp(() => backend = FakeBackend());

  testWidgets('login valida, muestra el error del backend e ingresa', (tester) async {
    final s = await servicesFor(tester, backend);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}, {'id': 2, 'name': 'Sur'}]));
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    await tester.pumpWidget(appOf(s));

    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(find.text('Ingrese su correo.'), findsOneWidget);
    expect(find.text('Ingrese su contraseña.'), findsOneWidget);
    expect(backend.calls, isEmpty);

    backend.on('POST /auth/login', (_) => apiError('INVALID_CREDENTIALS', 401));
    await tester.enterText(find.byKey(const Key('email')), 'carla@modaandina.test');
    await tester.enterText(find.byKey(const Key('password')), 'mala');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pumpAndSettle();
    expect(find.text('Credenciales inválidas. Verifique su correo y contraseña.'), findsOneWidget);

    backend.on('POST /auth/login', (_) => json(tokens(0)));
    await tester.enterText(find.byKey(const Key('password')), 'buena');
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pumpAndSettle();
    expect(find.text('Moda Andina S.R.L.'), findsOneWidget);
    expect(find.text('Cajero'), findsOneWidget);
    expect(find.text('Plan Básico'), findsOneWidget);
    expect(find.text('Centro'), findsOneWidget); // sucursal elegida por defecto
    // el cajero con plan offline descarga el catalogo al entrar (CU59)
    expect(backend.callsTo('GET /offline/catalog').length, 1);
    expect(find.textContaining('1 productos'), findsOneWidget);
    expect(find.text('Punto de venta'), findsOneWidget);
  });

  testWidgets('inicio: solo lectura, sin conexion, sucursales del catalogo descargado', (tester) async {
    final s = await servicesFor(tester, backend, online: false);
    await signIn(backend, s.auth, userJson(readOnly: true));
    await s.bootstrap.init();
    await s.catalog.save(catalogJson());
    backend.offline = true;
    await tester.pumpWidget(appOf(s));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('read-only')), findsOneWidget);
    expect(find.text('Sin conexión'), findsOneWidget);
    // sin red, la sucursal sale del catalogo descargado
    expect(find.text('Centro'), findsOneWidget);
  });

  testWidgets('sin sucursales asignadas avisa', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth, userJson(permissions: ['catalog.view']));
    backend.on('GET /branches/mine', (_) => json([]));
    await tester.pumpWidget(appOf(s));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-branches')), findsOneWidget);
    expect(find.text('Punto de venta'), findsNothing); // sin permiso de venta
    expect(find.byKey(const Key('catalog-card')), findsNothing); // sin sync.run
  });

  testWidgets('cerrar sesion con operaciones pendientes pide confirmacion y borra los datos locales', (tester) async {
    final s = await servicesFor(tester, backend, online: false);
    await signIn(backend, s.auth);
    await s.bootstrap.init();
    await s.catalog.save(catalogJson());
    await s.queue.enqueue(type: 'SALE', branchId: 1, userId: 20, payload: {'items': []}, summary: '1 prenda');
    backend.offline = true;
    await tester.pumpWidget(appOf(s));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    expect(find.text('Hay 1 operaciones sin sincronizar en este teléfono. Si cierra sesión se perderán.'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(s.auth.isAuthenticated, isTrue);

    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-button')), findsOneWidget);
    expect(await s.queue.all(), isEmpty);
    expect(s.catalog.info, isNull);
  });

  testWidgets('sesion vencida o empresa suspendida muestra el motivo y conserva los datos', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    backend.on('GET /offline/catalog', (_) => json(catalogJson()));
    await tester.pumpWidget(appOf(s));
    await tester.pumpAndSettle();
    s.auth.sessionEnded('TENANT_SUSPENDED');
    await tester.pumpAndSettle();
    expect(find.text('La empresa está suspendida. Comuníquese con el administrador de la plataforma.'), findsOneWidget);
    expect(s.catalog.info, isNotNull);
  });

  testWidgets('recuerda la sucursal elegida por usuario', (tester) async {
    final s = await servicesFor(tester, backend);
    await signIn(backend, s.auth);
    final store = s.branches.store;
    await store.write('fashionstore.branch.20', '2');
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}, {'id': 2, 'name': 'Sur'}]));
    await s.branches.load();
    expect(s.branches.selected?.name, 'Sur');
    await s.branches.select(s.branches.branches.first);
    expect(await store.read('fashionstore.branch.20'), '1');
  });
}
