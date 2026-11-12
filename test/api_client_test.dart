import 'package:fashionstore_movil/core/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());

  test('agrega el token y devuelve el JSON', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => json([{'id': 1, 'name': 'Centro'}]));
    final res = await s.api.get('/branches/mine');
    expect(res, [{'id': 1, 'name': 'Centro'}]);
    expect(backend.calls.single.auth, 'Bearer access-0');
  });

  test('normaliza el error del backend con mensaje en espanol', () async {
    final s = makeSession(backend);
    backend.on('POST /auth/login', (_) => apiError('INVALID_CREDENTIALS', 401));
    expect(
      () => s.auth.login('a@b.test', 'x'),
      throwsA(isA<ApiError>()
          .having((e) => e.code, 'code', 'INVALID_CREDENTIALS')
          .having((e) => e.message, 'message', 'Credenciales inválidas. Verifique su correo y contraseña.')),
    );
  });

  test('mensajes con datos del error', () {
    final e = ApiError.fromResponse(409, {
      'error': {'code': 'INSUFFICIENT_STOCK', 'message': 'x', 'details': {'available': 2, 'requested': 5}}
    });
    expect(e.message, 'Existencia insuficiente: hay 2 disponibles y se solicitaron 5.');
    expect(ApiError.fromResponse(500, 'Traceback').code, 'HTTP_ERROR');
  });

  test('sin conexion lanza NETWORK_ERROR', () async {
    final s = makeSession(backend);
    backend.offline = true;
    expect(() => s.api.get('/branches/mine'), throwsA(isA<ApiError>().having((e) => e.isNetwork, 'isNetwork', true)));
  });

  test('ante un 401 renueva el token una vez y reintenta', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    var n = 0;
    backend.on('GET /branches/mine', (c) => c.auth == 'Bearer access-1' ? json([]) : apiError('INVALID_TOKEN', 401));
    backend.on('POST /auth/refresh', (_) => json(tokens(++n)));
    expect(await s.api.get('/branches/mine'), []);
    expect(backend.callsTo('POST /auth/refresh').single.body, {'refresh_token': 'refresh-0'});
    expect(s.auth.accessToken, 'access-1');
  });

  test('varias peticiones con 401 comparten una sola renovacion', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (c) => c.auth == 'Bearer access-1' ? json([]) : apiError('INVALID_TOKEN', 401));
    backend.on('POST /auth/refresh', (_) => json(tokens(1)));
    await Future.wait([s.api.get('/branches/mine'), s.api.get('/branches/mine'), s.api.get('/branches/mine')]);
    expect(backend.callsTo('POST /auth/refresh').length, 1);
  });

  test('si la renovacion es rechazada cierra la sesion', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => apiError('INVALID_TOKEN', 401));
    backend.on('POST /auth/refresh', (_) => apiError('INVALID_REFRESH_TOKEN', 401));
    await expectLater(s.api.get('/branches/mine'), throwsA(isA<ApiError>()));
    expect(s.auth.isAuthenticated, isFalse);
    expect(s.auth.endReason, 'expired');
  });

  test('empresa suspendida cierra la sesion sin renovar (CU53 A1)', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) => apiError('TENANT_SUSPENDED', 403));
    await expectLater(s.api.get('/branches/mine'), throwsA(isA<ApiError>()));
    await pumpEventQueue();
    expect(backend.callsTo('POST /auth/refresh'), isEmpty);
    expect(s.auth.isAuthenticated, isFalse);
    expect(s.auth.endReason, 'TENANT_SUSPENDED');
  });

  test('un 403 de permiso o de solo lectura no cierra la sesion', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    for (final code in ['PERMISSION_DENIED', 'FEATURE_NOT_IN_PLAN', 'SUBSCRIPTION_NOT_CURRENT']) {
      backend.on('POST /sales', (_) => apiError(code, 403));
      await expectLater(s.api.post('/sales', body: {}), throwsA(isA<ApiError>().having((e) => e.code, 'code', code)));
    }
    expect(s.auth.isAuthenticated, isTrue);
  });

  test('sin conexion durante la renovacion conserva la sesion', () async {
    final s = makeSession(backend);
    await signIn(backend, s.auth);
    backend.on('GET /branches/mine', (_) {
      backend.offline = true; // se cae la red despues del 401
      return apiError('INVALID_TOKEN', 401);
    });
    await expectLater(s.api.get('/branches/mine'), throwsA(isA<ApiError>().having((e) => e.isNetwork, 'net', true)));
    expect(s.auth.isAuthenticated, isTrue);
  });
}
