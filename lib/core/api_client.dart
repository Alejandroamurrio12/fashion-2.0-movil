import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'config.dart';

/// Lo que el cliente HTTP necesita de la sesion (lo implementa AuthService).
abstract class SessionHooks {
  String? get accessToken;
  bool get hasRefreshToken;

  /// Renueva el access token. true: renovado; false: la sesion se cerro.
  /// Lanza ApiError.network() si no hay conexion (la sesion se conserva).
  Future<bool> refreshSession();

  /// El backend rechazo la sesion (empresa suspendida, usuario inactivo).
  void sessionEnded(String reason);
}

/// Errores que cierran la sesion sin intentar renovarla (CU53 A1).
const fatalCodes = {'TENANT_SUSPENDED', 'USER_INACTIVE'};

/// Cliente del backend. Agrega el JWT, renueva el token una vez ante un 401 y reintenta,
/// y convierte cualquier error en ApiError (formato {"error": {code, message, details}}).
class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.apiUrl;

  final http.Client _client;
  final String baseUrl;
  SessionHooks? hooks;

  Future<dynamic> get(String path, {Map<String, Object?>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, {Object? body, bool auth = true}) => _send('POST', path, body: body, auth: auth);
  Future<dynamic> put(String path, {Object? body}) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, {Object? body}) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Uri uri(String path, [Map<String, Object?>? query]) {
    final params = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && '$v'.isNotEmpty) params[k] = '$v';
    });
    final u = Uri.parse('$baseUrl$path');
    return params.isEmpty ? u : u.replace(queryParameters: params);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? query,
    bool auth = true,
    bool retry = true,
  }) async {
    final request = http.Request(method, uri(path, query))
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final token = auth ? hooks?.accessToken : null;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(request).timeout(AppConfig.requestTimeout));
    } on SocketException {
      throw ApiError.network();
    } on http.ClientException {
      throw ApiError.network();
    } on TimeoutException {
      throw ApiError.network();
    }

    final decoded = _decode(res);
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;

    final error = ApiError.fromResponse(res.statusCode, decoded);
    if (!auth || hooks == null) throw error;
    if (fatalCodes.contains(error.code)) {
      hooks!.sessionEnded(error.code);
      throw error;
    }
    if (res.statusCode == 401) {
      if (retry && hooks!.hasRefreshToken) {
        if (await hooks!.refreshSession()) {
          return _send(method, path, body: body, query: query, auth: auth, retry: false);
        }
      } else if (!hooks!.hasRefreshToken) {
        hooks!.sessionEnded('expired');
      }
    }
    throw error;
  }

  Object? _decode(http.Response res) {
    if (res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      return null;
    }
  }
}
