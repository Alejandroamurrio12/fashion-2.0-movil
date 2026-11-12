import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Estado de conexion del dispositivo. Avisa cuando vuelve la conexion (para sincronizar).
class ConnectivityService extends ChangeNotifier {
  // los parametros con nombre no pueden ser privados, por eso no se usa this._online
  // ignore: prefer_initializing_formals
  ConnectivityService({Stream<List<ConnectivityResult>>? changes, bool initiallyOnline = true})
      : _online = initiallyOnline {
    _sub = (changes ?? Connectivity().onConnectivityChanged).listen(_update);
  }

  /// Version para pruebas: el estado se cambia a mano con [setOnline].
  // ignore: prefer_initializing_formals
  ConnectivityService.manual({bool online = true}) : _online = online;

  bool _online;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool get online => _online;

  /// Consulta el estado actual (al iniciar la app).
  Future<void> check() async {
    _update(await Connectivity().checkConnectivity());
  }

  void setOnline(bool value) {
    if (value == _online) return;
    _online = value;
    notifyListeners();
  }

  void _update(List<ConnectivityResult> results) {
    setOnline(results.any((r) => r != ConnectivityResult.none));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
