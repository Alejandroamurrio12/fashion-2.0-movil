import 'dart:convert';
import 'dart:io';

import 'package:fashionstore_movil/auth/auth_service.dart';
import 'package:fashionstore_movil/core/api_client.dart';
import 'package:fashionstore_movil/core/connectivity_service.dart';
import 'package:fashionstore_movil/core/secure_store.dart';
import 'package:fashionstore_movil/main.dart';
import 'package:fashionstore_movil/offline/local_db.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const api = 'http://test/api/v1';

/// Peticion registrada por el backend simulado.
class Call {
  Call(this.method, this.path, this.query, this.body, this.auth);
  final String method;
  final String path;
  final Map<String, String> query;
  final Object? body;
  final String? auth;
}

typedef Handler = http.Response Function(Call call);

/// Backend simulado: responde segun "METODO /ruta" y registra cada llamada.
class FakeBackend {
  final Map<String, Handler> routes = {};
  final List<Call> calls = [];
  bool offline = false;

  void on(String key, Handler handler) => routes[key] = handler;

  List<Call> callsTo(String key) => calls.where((c) => '${c.method} ${c.path}' == key).toList();

  late final client = MockClient((req) async {
    if (offline) throw http.ClientException('sin red');
    final path = req.url.path.replaceFirst('/api/v1', '');
    final call = Call(req.method, path, req.url.queryParameters, req.body.isEmpty ? null : jsonDecode(req.body),
        req.headers['Authorization']);
    calls.add(call);
    final handler = routes['${req.method} $path'];
    if (handler == null) return json({'error': {'code': 'NOT_FOUND', 'message': 'x'}}, 404);
    return handler(call);
  });
}

http.Response json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

http.Response apiError(String code, int status, [Object? details]) =>
    json({'error': {'code': code, 'message': 'msg', 'details': details}}, status);

Map<String, dynamic> userJson({
  int id = 20,
  String role = 'CAJERO',
  List<String> permissions = const ['sales.create', 'sync.run', 'inventory.view', 'customers.view', 'catalog.view'],
  bool readOnly = false,
  bool platform = false,
  Map<String, bool>? features,
}) =>
    {
      'id': id,
      'email': 'carla@modaandina.test',
      'full_name': 'Carla Caja',
      'role': role,
      'permissions': permissions,
      'is_platform_admin': platform,
      'read_only': readOnly,
      'tenant': platform ? null : {'id': 1, 'legal_name': 'Moda Andina S.R.L.', 'status': 'ACTIVE'},
      'subscription': platform
          ? null
          : {
              'plan_code': 'BASIC',
              'plan_name': 'Básico',
              'status': 'ACTIVE',
              'end_date': '2026-12-31',
              'is_current': !readOnly,
              'days_remaining': 51,
              'max_active_branches': 2,
              'features': features ??
                  {
                    'products': true,
                    'sales': true,
                    'reservations': true,
                    'offline': true,
                    'conventional_reports': true,
                    'generative_reports': false,
                    'report_export': true,
                    'ml_analytics': false,
                  },
            },
    };

Map<String, dynamic> tokens(int n, [Map<String, dynamic>? user]) =>
    {'access_token': 'access-$n', 'token_type': 'bearer', 'expires_in': 1800, 'refresh_token': 'refresh-$n', 'user': user ?? userJson()};

/// Cliente + sesion sobre el backend simulado.
({ApiClient api, AuthService auth, MemorySecureStore store}) makeSession(FakeBackend backend) {
  final store = MemorySecureStore();
  final client = ApiClient(client: backend.client, baseUrl: api);
  final auth = AuthService(client, store);
  return (api: client, auth: auth, store: store);
}

/// Deja la sesion iniciada con access-0 / refresh-0.
Future<void> signIn(FakeBackend backend, AuthService auth, [Map<String, dynamic>? user]) async {
  backend.on('POST /auth/login', (_) => json(tokens(0, user)));
  await auth.login('carla@modaandina.test', 'secreta');
  backend.calls.clear();
}

// ---------------------------------------------------------------- M2+: servicios con SQLite real

/// Base SQLite en un archivo temporal (sqflite_common_ffi, sin isolate para las pruebas de pantalla).
Future<LocalDb> openTestDb() {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('fs-movil-');
  return LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: '${dir.path}/test.db');
}

Future<AppServices> makeServices(FakeBackend backend, {bool online = true}) async {
  final store = MemorySecureStore();
  final client = ApiClient(client: backend.client, baseUrl: api);
  final auth = AuthService(client, store);
  return AppServices.wire(
    api: client,
    auth: auth,
    store: store,
    connectivity: ConnectivityService.manual(online: online),
    local: await openTestDb(),
    syncInterval: null, // sin temporizador en las pruebas
  );
}

Map<String, dynamic> catalogJson({DateTime? generatedAt}) => {
      'generated_at': (generatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'max_age_hours': 24,
      'currency': 'BOB',
      'tenant': {'id': 1, 'legal_name': 'Moda Andina S.R.L.'},
      'branches': [
        {'id': 1, 'name': 'Centro', 'city': 'La Paz', 'address': null},
        {'id': 2, 'name': 'Sur', 'city': 'La Paz', 'address': null},
      ],
      'products': [
        {
          'id': 1,
          'code': 'CAM-OX',
          'name': 'Camisa Oxford',
          'category': 'Camisas',
          'brand': 'Andina',
          'base_price': 120,
          'cover_image_url': null,
          'variants': [
            {'id': 11, 'sku': 'CAM-OX-M-NEG', 'size': 'M', 'color': 'Negro', 'hex_code': '#000000', 'price': 120},
            {'id': 12, 'sku': 'CAM-OX-L-NEG', 'size': 'L', 'color': 'Negro', 'hex_code': '#000000', 'price': 130},
          ],
        },
      ],
      'stock': [
        {'branch_id': 1, 'product_variant_id': 11, 'available_quantity': 5},
        {'branch_id': 1, 'product_variant_id': 12, 'available_quantity': 2},
      ],
      'customers': [
        {'id': 40, 'full_name': 'Luis Cliente', 'document_number': '1234567'},
      ],
    };

/// En pruebas de pantalla: abrir la base hace E/S real de archivos, que no avanza dentro del
/// reloj simulado de testWidgets; por eso se abre con runAsync.
Future<AppServices> servicesFor(WidgetTester tester, FakeBackend backend, {bool online = true}) async =>
    (await tester.runAsync(() => makeServices(backend, online: online)))!;
