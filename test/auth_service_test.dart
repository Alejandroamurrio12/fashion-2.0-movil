import 'dart:convert';

import 'package:fashionstore_movil/core/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());

  test('login guarda tokens y usuario, sin la contrasena', () async {
    final s = makeSession(backend);
    backend.on('POST /auth/login', (_) => json(tokens(0)));
    final me = await s.auth.login('carla@modaandina.test', 'secreta');
    expect(me.fullName, 'Carla Caja');
    expect(s.auth.isAuthenticated, isTrue);
    expect(backend.calls.single.auth, isNull);
    final stored = s.store.values['fashionstore.session']!;
    expect(stored, isNot(contains('secreta')));
    expect(jsonDecode(stored)['refresh'], 'refresh-0');
  });

  test('permisos y funciones del plan', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    expect(s.auth.hasPermissions(['sales.create', 'sync.run']), isTrue);
    expect(s.auth.hasPermissions(['branches.manage']), isFalse);
    expect(s.auth.hasAnyPermission(['reservations.manage', 'sync.run']), isTrue);
    expect(s.auth.hasFeature('offline'), isTrue);
    expect(s.auth.hasFeature('ml_analytics'), isFalse);
  });

  test('el administrador de plataforma usa la aplicacion web', () async {
    final s = makeSession(backend);
    backend.on('POST /auth/login', (_) => json(tokens(0, userJson(platform: true, role: 'ADMIN_PLATAFORMA'))));
    backend.on('POST /auth/logout', (_) => json(null, 204));
    await expectLater(s.auth.login('admin@fs.test', 'x'), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'PLATFORM_ON_WEB')));
    expect(s.auth.isAuthenticated, isFalse);
    expect(backend.callsTo('POST /auth/logout').single.body, {'refresh_token': 'refresh-0'});
  });

  test('restore recupera la sesion y actualiza el plan desde /auth/me', () async {
    final first = makeSession(backend);
    await signIn(backend, first.auth);
    final second = makeSession(backend);
    second.store.values.addAll(first.store.values);
    backend.on('GET /auth/me', (_) => json(userJson(readOnly: true)));
    await second.auth.restore();
    expect(second.auth.isAuthenticated, isTrue);
    expect(second.auth.readOnly, isTrue);
  });

  test('restore sin conexion conserva la sesion guardada', () async {
    final first = makeSession(backend);
    await signIn(backend, first.auth);
    final second = makeSession(backend);
    second.store.values.addAll(first.store.values);
    backend.offline = true;
    await second.auth.restore();
    expect(second.auth.isAuthenticated, isTrue);
  });

  test('restore ignora una sesion guardada corrupta', () async {
    final s = makeSession(backend);
    s.store.values['fashionstore.session'] = '{no es json';
    await s.auth.restore();
    expect(s.auth.isAuthenticated, isFalse);
    expect(s.store.values, isEmpty);
  });

  test('logout revoca, limpia y avisa para borrar los datos locales (RNF16)', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    var wiped = false;
    s.auth.onLogout.add(() async => wiped = true);
    backend.on('POST /auth/logout', (_) => json(null, 204));
    await s.auth.logout();
    expect(backend.callsTo('POST /auth/logout').single.body, {'refresh_token': 'refresh-0'});
    expect(s.auth.isAuthenticated, isFalse);
    expect(s.store.values, isEmpty);
    expect(wiped, isTrue);
  });

  test('si la sesion vence NO se borran los datos locales (operaciones pendientes)', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    var wiped = false;
    s.auth.onLogout.add(() async => wiped = true);
    backend.on('GET /branches/mine', (_) => apiError('INVALID_TOKEN', 401));
    backend.on('POST /auth/refresh', (_) => apiError('INVALID_REFRESH_TOKEN', 401));
    await expectLater(s.api.get('/branches/mine'), throwsA(isA<ApiError>()));
    expect(s.auth.isAuthenticated, isFalse);
    expect(wiped, isFalse);
  });

  test('logout sin conexion cierra la sesion local igual', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.offline = true;
    await s.auth.logout();
    expect(s.auth.isAuthenticated, isFalse);
  });
}
