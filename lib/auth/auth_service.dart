import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/api_error.dart';
import '../core/secure_store.dart';
import 'models.dart';

/// Sesion del usuario (CU58). Guarda tokens y usuario en el almacenamiento seguro para que la
/// app abra sin conexion con el ultimo usuario (operacion offline). La contrasena nunca se guarda.
class AuthService extends ChangeNotifier implements SessionHooks {
  AuthService(this.api, this.store) {
    api.hooks = this;
  }

  final ApiClient api;
  final SecureStore store;
  static const _key = 'fashionstore.session';

  Me? _me;
  String? _access;
  String? _refresh;
  Future<bool>? _refreshing;

  /// Motivo del ultimo cierre de sesion forzado ('expired', 'TENANT_SUSPENDED', 'USER_INACTIVE').
  String? endReason;

  /// Se llama cuando el usuario cierra sesion (borrar los datos locales, RNF16). No se llama
  /// si la sesion vence o la empresa se suspende: las operaciones pendientes se conservan.
  final List<Future<void> Function()> onLogout = [];

  Me? get me => _me;
  bool get isAuthenticated => _me != null && _access != null;
  bool get readOnly => _me?.readOnly ?? false;

  @override
  String? get accessToken => _access;

  @override
  bool get hasRefreshToken => _refresh != null;

  bool hasPermissions(Iterable<String> permissions) {
    final granted = _me?.permissions ?? const [];
    return permissions.every(granted.contains);
  }

  bool hasAnyPermission(Iterable<String> permissions) => permissions.any((p) => hasPermissions([p]));

  /// true si el plan de la empresa habilita la funcion (CU57).
  bool hasFeature(String feature) => _me?.subscription?.features[feature] == true;

  /// Al abrir la app: recupera la sesion guardada y la valida con /auth/me. Sin conexion se
  /// conserva la sesion guardada; si el backend la rechaza, se cierra.
  Future<void> restore() async {
    final raw = await store.read(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _access = j['access'] as String;
      _refresh = j['refresh'] as String;
      _me = Me.fromJson(j['user'] as Map<String, dynamic>);
    } catch (_) {
      await store.delete(_key);
      return;
    }
    notifyListeners();
    try {
      await loadMe();
    } on ApiError {
      // sin conexion: se sigue con la sesion guardada; si fue rechazada, ya se cerro
    }
  }

  Future<Me> login(String email, String password) async {
    endReason = null;
    final res = await api.post('/auth/login', body: {'email': email, 'password': password}, auth: false);
    final user = Me.fromJson(res['user'] as Map<String, dynamic>);
    if (user.isPlatformAdmin) {
      // la administracion de la plataforma se hace en la aplicacion web
      await _revoke(res['refresh_token'] as String);
      throw ApiError(
        status: 403,
        code: 'PLATFORM_ON_WEB',
        message: 'La administración de la plataforma se hace en la aplicación web.',
      );
    }
    await _storeTokens(res as Map<String, dynamic>);
    return user;
  }

  Future<Me> loadMe() async {
    final res = await api.get('/auth/me');
    _me = Me.fromJson(res as Map<String, dynamic>);
    await _persist();
    notifyListeners();
    return _me!;
  }

  /// Una sola renovacion aunque varias peticiones reciban 401 a la vez.
  @override
  Future<bool> refreshSession() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final token = _refresh;
    if (token == null) return false;
    try {
      final res = await api.post('/auth/refresh', body: {'refresh_token': token}, auth: false);
      await _storeTokens(res as Map<String, dynamic>);
      return true;
    } on ApiError catch (e) {
      if (e.isNetwork) rethrow; // sin conexion: se conserva la sesion
      await _clear(fatalCodes.contains(e.code) ? e.code : 'expired');
      return false;
    }
  }

  @override
  void sessionEnded(String reason) {
    unawaited(_clear(reason));
  }

  Future<void> logout() async {
    final token = _refresh;
    if (token != null) await _revoke(token);
    await _clear(null);
  }

  Future<void> _revoke(String refreshToken) async {
    try {
      await api.post('/auth/logout', body: {'refresh_token': refreshToken}, auth: false);
    } on ApiError {
      // sin conexion: el token vence solo; la sesion local se cierra igual
    }
  }

  Future<void> _storeTokens(Map<String, dynamic> res) async {
    _access = res['access_token'] as String;
    _refresh = res['refresh_token'] as String;
    _me = Me.fromJson(res['user'] as Map<String, dynamic>);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_access == null || _refresh == null || _me == null) return;
    await store.write(_key, jsonEncode({'access': _access, 'refresh': _refresh, 'user': _me!.toJson()}));
  }

  Future<void> _clear(String? reason) async {
    final explicitLogout = reason == null && _me != null;
    _me = null;
    _access = null;
    _refresh = null;
    _refreshing = null;
    endReason = reason;
    await store.delete(_key);
    if (explicitLogout) {
      for (final callback in onLogout) {
        await callback();
      }
    }
    notifyListeners();
  }
}
