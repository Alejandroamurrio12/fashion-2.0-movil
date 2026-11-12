// Prueba contra el backend REAL (base de pruebas). No se ejecuta con `flutter test` normal:
//   flutter test test_api/backend_smoke_test.dart --dart-define=API_URL=http://127.0.0.1:8000/api/v1
// Lee la credencial del administrador de plataforma de ../fashion-2.0-backend/.env sin imprimirla.
import 'dart:io';
import 'dart:math';

import 'package:fashionstore_movil/auth/auth_service.dart';
import 'package:fashionstore_movil/branch/branch_service.dart';
import 'package:fashionstore_movil/core/api_client.dart';
import 'package:fashionstore_movil/core/api_error.dart';
import 'package:fashionstore_movil/core/secure_store.dart';
import 'package:fashionstore_movil/offline/catalog_store.dart';
import 'package:fashionstore_movil/offline/local_db.dart';
import 'package:fashionstore_movil/offline/operation_queue.dart';
import 'package:fashionstore_movil/offline/sync_service.dart';
import 'package:fashionstore_movil/core/connectivity_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:8000/api/v1');

Map<String, String> readEnv() {
  final lines = File('../fashion-2.0-backend/.env').readAsLinesSync();
  return {
    for (final l in lines)
      if (l.contains('=') && !l.trimLeft().startsWith('#'))
        l.substring(0, l.indexOf('=')).trim(): l.substring(l.indexOf('=') + 1).trim().replaceAll(RegExp('^["\']|["\']\$'), ''),
  };
}

String today([int days = 0]) => DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10);

void main() {
  final env = readEnv();
  final nit = '2${Random().nextInt(899999999) + 100000000}';
  final pass = 'Clave-$nit';

  m3Tests(env);
  m4Tests(env);

  test('M1 contra el backend real: login, renovacion, sucursales, empresa suspendida', () async {
    // preparacion con el administrador de plataforma (la app movil no lo admite)
    final platform = ApiClient(baseUrl: apiUrl);
    final login = await platform.post('/auth/login', body: {'email': env['PLATFORM_ADMIN_EMAIL'], 'password': env['PLATFORM_ADMIN_PASSWORD']}, auth: false);
    final pToken = login['access_token'] as String;
    final plans = await _get(platform, '/platform/plans', pToken) as List;
    final basic = plans.firstWhere((p) => p['code'] == 'BASIC');
    final tenant = await _post(platform, '/platform/tenants', pToken, {
      'tenant': {'legal_name': 'Movil M1 $nit', 'nit': nit, 'contact_email': null, 'contact_phone': null, 'address': null},
      'admin': {'first_name': 'Ada', 'last_name': null, 'email': 'admin$nit@smoke.test', 'password': pass, 'phone': null},
      'subscription': {'plan_id': basic['id'], 'start_date': today(), 'end_date': today(30)},
    });

    // la app: el administrador de plataforma no entra
    final app = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await expectLater(app.login(env['PLATFORM_ADMIN_EMAIL']!, env['PLATFORM_ADMIN_PASSWORD']!),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'PLATFORM_ON_WEB')));

    // credenciales invalidas
    await expectLater(app.login('admin$nit@smoke.test', 'mala-clave'),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'INVALID_CREDENTIALS')));

    // login del administrador de la empresa: permisos y plan reales
    final me = await app.login('admin$nit@smoke.test', pass);
    expect(me.role, 'ADMINISTRADOR');
    expect(app.hasFeature('offline'), isTrue);
    expect(app.hasFeature('ml_analytics'), isFalse);

    // sucursales: crea 2 y las ve en /branches/mine
    for (final name in ['Centro', 'Sur']) {
      await app.api.post('/branches', body: {'name': name, 'city': null, 'address': null, 'phone': null, 'is_active': true});
    }
    final branches = BranchService(app.api, app, app.store);
    await branches.load();
    expect(branches.branches.map((b) => b.name).toSet(), {'Centro', 'Sur'});

    // renovacion real: un access token invalido se renueva y la peticion se reintenta
    final refreshBefore = app.hasRefreshToken;
    final forced = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await forced.login('admin$nit@smoke.test', pass);
    // se invalida el access token guardando uno falso en la sesion persistida y restaurando
    final store = forced.store as MemorySecureStore;
    store.values['fashionstore.session'] = store.values['fashionstore.session']!.replaceFirst(RegExp(r'"access":"[^"]+"'), '"access":"x.y.z"');
    final restored = AuthService(ApiClient(baseUrl: apiUrl), store);
    await restored.restore();
    expect(refreshBefore, isTrue);
    expect(restored.isAuthenticated, isTrue);
    expect(restored.accessToken, isNot('x.y.z'));

    // empresa suspendida: la app cierra la sesion con el motivo (CU53 A1)
    await _patch(platform, '/platform/tenants/${tenant['id']}/status', pToken, {'status': 'SUSPENDED', 'reason': 'prueba movil'});
    await expectLater(app.loadMe(), throwsA(isA<ApiError>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(app.isAuthenticated, isFalse);
    expect(app.endReason, 'TENANT_SUSPENDED');
  });
}

void m3Tests(Map<String, String> env) {
  test('M2 y M3 contra el backend real: catalogo offline, venta en linea y venta en la cola', () async {
    final nit = '1${Random().nextInt(899999999) + 100000000}';
    final pass = 'Clave-$nit';
    final platform = ApiClient(baseUrl: apiUrl);
    final login = await platform.post('/auth/login', body: {'email': env['PLATFORM_ADMIN_EMAIL'], 'password': env['PLATFORM_ADMIN_PASSWORD']}, auth: false);
    final pToken = login['access_token'] as String;
    final plans = await _get(platform, '/platform/plans', pToken) as List;
    final basic = plans.firstWhere((p) => p['code'] == 'BASIC');
    await _post(platform, '/platform/tenants', pToken, {
      'tenant': {'legal_name': 'Movil M3 $nit', 'nit': nit, 'contact_email': null, 'contact_phone': null, 'address': null},
      'admin': {'first_name': 'Ada', 'last_name': null, 'email': 'admin$nit@smoke.test', 'password': pass, 'phone': null},
      'subscription': {'plan_id': basic['id'], 'start_date': today(), 'end_date': today(30)},
    });

    // datos de la empresa con su administrador
    final admin = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await admin.login('admin$nit@smoke.test', pass);
    final a = admin.api;
    final branch = await a.post('/branches', body: {'name': 'Centro', 'city': null, 'address': null, 'phone': null, 'is_active': true});
    final cat = await a.post('/categories', body: {'name': 'Camisas', 'description': null});
    final size = await a.post('/sizes', body: {'name': 'M'});
    final color = await a.post('/colors', body: {'name': 'Negro', 'hex_code': null});
    final product = await a.post('/products', body: {
      'code': 'CAM', 'name': 'Camisa', 'category_id': cat['id'], 'brand': null, 'base_price': 100, 'description': null,
      'cover_image_url': null, 'is_active': true,
      'variants': [{'size_id': size['id'], 'color_id': color['id'], 'sku': null, 'additional_price': 0}],
    });
    final variantId = (product['variants'] as List).first['id'] as int;
    await a.post('/inventory/movements', body: {'branch_id': branch['id'], 'product_variant_id': variantId, 'movement_type': 'ENTRY', 'quantity': 10, 'reason': null, 'notes': null});
    await a.post('/users', body: {'first_name': 'Carla', 'last_name': null, 'email': 'caj$nit@smoke.test', 'password': pass, 'phone': null, 'document_number': null, 'role': 'CAJERO', 'branch_ids': [branch['id']]});

    // la app con el cajero: catalogo offline a SQLite (CU59)
    final cashier = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await cashier.login('caj$nit@smoke.test', pass);
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('fs-movil-api-');
    final local = await LocalDb.open(factory: databaseFactoryFfi, path: '${dir.path}/api.db');
    final catalog = CatalogStore(local, cashier.api);
    await catalog.ensureOwner(cashier.me!.id, cashier.me!.tenant?.id);
    final info = await catalog.download();
    expect(info.products, 1);
    expect(await catalog.available(branch['id'] as int, variantId), 10);
    expect((await catalog.search('camisa')).single.price, 100);
    expect((await catalog.branches()).single.name, 'Centro');

    // venta en linea con el mismo cuerpo que arma PosScreen (CU35-CU37)
    final sale = await cashier.api.post('/sales', body: {
      'branch_id': branch['id'], 'customer_id': null, 'reservation_id': null,
      'items': [{'product_variant_id': variantId, 'quantity': 2}],
      'payment': {'method': 'CASH', 'amount_received': 250.0, 'external_reference': null},
      'tax_id': '1234567', 'tax_name': null,
    });
    expect(sale['total_amount'], 200);
    final receipt = await cashier.api.get('/sales/${sale['id']}/receipt');
    expect(receipt['payments'][0]['change_amount'], 50);
    expect(receipt['tax_id'], '1234567');

    // venta sin conexion: queda en la cola local (se envia en M4) y descuenta el stock local
    final queue = OperationQueue(local);
    final op = await queue.enqueue(type: 'SALE', branchId: branch['id'] as int, userId: cashier.me!.id, summary: '1 prenda', payload: {
      'customer_id': null,
      'items': [{'product_variant_id': variantId, 'quantity': 1, 'unit_price': 100.0}],
      'payment': {'method': 'CASH', 'amount_received': null}, 'tax_id': null, 'tax_name': null,
    });
    await catalog.adjustStock(branch['id'] as int, variantId, -1);
    expect(op.status, OpStatus.local);
    expect(await catalog.available(branch['id'] as int, variantId), 9);
    await local.close();
  });
}

void m4Tests(Map<String, String> env) {
  test('M4 contra el backend real: dos telefonos venden offline la ultima unidad (pregunta 5)', () async {
    final nit = '3${Random().nextInt(899999999) + 100000000}';
    final pass = 'Clave-$nit';
    final platform = ApiClient(baseUrl: apiUrl);
    final login = await platform.post('/auth/login', body: {'email': env['PLATFORM_ADMIN_EMAIL'], 'password': env['PLATFORM_ADMIN_PASSWORD']}, auth: false);
    final pToken = login['access_token'] as String;
    final plans = await _get(platform, '/platform/plans', pToken) as List;
    final basic = plans.firstWhere((p) => p['code'] == 'BASIC');
    await _post(platform, '/platform/tenants', pToken, {
      'tenant': {'legal_name': 'Movil M4 $nit', 'nit': nit, 'contact_email': null, 'contact_phone': null, 'address': null},
      'admin': {'first_name': 'Ada', 'last_name': null, 'email': 'admin$nit@smoke.test', 'password': pass, 'phone': null},
      'subscription': {'plan_id': basic['id'], 'start_date': today(), 'end_date': today(30)},
    });
    final admin = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await admin.login('admin$nit@smoke.test', pass);
    final a = admin.api;
    final branch = await a.post('/branches', body: {'name': 'Centro', 'city': null, 'address': null, 'phone': null, 'is_active': true});
    final cat = await a.post('/categories', body: {'name': 'Camisas', 'description': null});
    final size = await a.post('/sizes', body: {'name': 'M'});
    final color = await a.post('/colors', body: {'name': 'Negro', 'hex_code': null});
    final product = await a.post('/products', body: {
      'code': 'CAM', 'name': 'Camisa', 'category_id': cat['id'], 'brand': null, 'base_price': 100, 'description': null,
      'cover_image_url': null, 'is_active': true,
      'variants': [{'size_id': size['id'], 'color_id': color['id'], 'sku': null, 'additional_price': 0}],
    });
    final variantId = (product['variants'] as List).first['id'] as int;
    final branchId = branch['id'] as int;
    // queda UNA sola unidad
    await a.post('/inventory/movements', body: {'branch_id': branchId, 'product_variant_id': variantId, 'movement_type': 'ENTRY', 'quantity': 1, 'reason': null, 'notes': null});
    for (final who in ['ana', 'beto']) {
      await a.post('/users', body: {'first_name': who, 'last_name': null, 'email': '$who$nit@smoke.test', 'password': pass, 'phone': null, 'document_number': null, 'role': 'CAJERO', 'branch_ids': [branchId]});
    }
    await a.post('/users', body: {'first_name': 'Ena', 'last_name': null, 'email': 'enc$nit@smoke.test', 'password': pass, 'phone': null, 'document_number': null, 'role': 'ENCARGADO', 'branch_ids': [branchId]});

    // dos telefonos, cada uno con su base, su catalogo (stock 1) y su cola
    sqfliteFfiInit();
    Future<({AuthService auth, CatalogStore catalog, OperationQueue queue, SyncService sync, ConnectivityService net})> phone(String who) async {
      final auth = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
      await auth.login('$who$nit@smoke.test', pass);
      final dir = Directory.systemTemp.createTempSync('fs-$who-');
      final local = await LocalDb.open(factory: databaseFactoryFfi, path: '${dir.path}/$who.db');
      final catalog = CatalogStore(local, auth.api);
      await catalog.ensureOwner(auth.me!.id, auth.me!.tenant?.id);
      await catalog.download();
      final queue = OperationQueue(local);
      final net = ConnectivityService.manual(online: false);
      final sync = SyncService(auth.api, auth, net, queue, interval: null);
      return (auth: auth, catalog: catalog, queue: queue, sync: sync, net: net);
    }

    final ana = await phone('ana');
    final beto = await phone('beto');
    expect(await ana.catalog.available(branchId, variantId), 1);
    expect(await beto.catalog.available(branchId, variantId), 1);

    // ambos venden SIN CONEXION la ultima unidad (cada uno ve stock 1 en su telefono)
    Future<QueuedOperation> sellOffline(dynamic p) async {
      final op = await p.queue.enqueue(type: 'SALE', branchId: branchId, userId: p.auth.me!.id, summary: '1 prenda', payload: {
        'customer_id': null,
        'items': [{'product_variant_id': variantId, 'quantity': 1, 'unit_price': 100.0}],
        'payment': {'method': 'CASH', 'amount_received': null}, 'tax_id': null, 'tax_name': null,
      });
      await p.catalog.adjustStock(branchId, variantId, -1);
      return op as QueuedOperation;
    }

    final opAna = await sellOffline(ana);
    final opBeto = await sellOffline(beto);
    expect(await ana.sync.sync(force: true), isNull); // sin conexion no envia

    // vuelve la conexion: primero llega Ana, despues Beto
    ana.net.setOnline(true);
    final sa = await ana.sync.sync();
    beto.net.setOnline(true);
    final sb = await beto.sync.sync();
    expect(sa!.confirmed, 1);
    expect(sb!.conflicts, 1);
    final anaOp = (await ana.queue.all()).single;
    final betoOp = (await beto.queue.all()).single;
    expect(anaOp.status, OpStatus.confirmed);
    expect(anaOp.result?['resource_code'], startsWith('V-'));
    expect(betoOp.status, OpStatus.inConflict);
    expect(betoOp.result?['conflict_type'], 'STOCK');

    // el inventario NO quedo negativo: la venta de Beto no toco el stock (RN-12)
    final inv = await a.get('/inventory', query: {'branch_id': branchId, 'limit': 100}) as List;
    expect(inv.single['stock_quantity'], 0);

    // reenviar es idempotente: Ana vuelve a mandar su UUID y no se duplica la venta (RN-09)
    final again = await ana.auth.api.post('/sync/operations', body: {'device_id': 'x', 'operations': [opAna.toSync()]});
    expect((again['results'] as List).single['duplicate'], isTrue);
    final sales = await a.get('/sales', query: {'branch_id': branchId, 'limit': 50}) as List;
    expect(sales.length, 1);

    // el encargado ve el conflicto y decide (CU63)
    final manager = AuthService(ApiClient(baseUrl: apiUrl), MemorySecureStore());
    await manager.login('enc$nit@smoke.test', pass);
    final conflicts = await manager.api.get('/sync/conflicts', query: {'status': 'OPEN'}) as List;
    final c = conflicts.single as Map<String, dynamic>;
    expect(c['conflict_type'], 'STOCK');
    expect(c['allowed_decisions'], ['ACCEPT_PARTIAL', 'ADJUST_INVENTORY', 'CANCEL']);
    expect((c['detail']['lines'] as List).single['available'], 0);
    expect(c['operation']['client_operation_id'], opBeto.clientOperationId);
    await manager.api.post('/sync/conflicts/${c['id']}/resolve', body: {'decision': 'CANCEL', 'notes': 'Ya se vendio en otro telefono'});

    // el telefono de Beto se entera al consultar el estado (CU62)
    await beto.sync.refreshStatuses();
    expect((await beto.queue.all()).single.status, OpStatus.cancelled);
  });
}

// llamadas de preparacion con el token de plataforma (fuera de la sesion de la app)
Future<dynamic> _get(ApiClient c, String path, String token) => _with(c, token, () => c.get(path));
Future<dynamic> _post(ApiClient c, String path, String token, Object body) => _with(c, token, () => c.post(path, body: body));
Future<dynamic> _patch(ApiClient c, String path, String token, Object body) => _with(c, token, () => c.patch(path, body: body));

Future<dynamic> _with(ApiClient c, String token, Future<dynamic> Function() call) {
  c.hooks = _StaticToken(token);
  return call();
}

class _StaticToken implements SessionHooks {
  _StaticToken(this.accessToken);
  @override
  final String? accessToken;
  @override
  bool get hasRefreshToken => false;
  @override
  Future<bool> refreshSession() async => false;
  @override
  void sessionEnded(String reason) {}
}
