import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';
import 'catalog_store.dart';
import 'operation_queue.dart';

/// Prepara la operacion sin conexion al entrar: asocia la base local al usuario (RN-22),
/// carga la cola y descarga el catalogo si falta o esta vencido.
class OfflineBootstrap extends ChangeNotifier {
  OfflineBootstrap(this.auth, this.connectivity, this.catalog, this.queue);

  final AuthService auth;
  final ConnectivityService connectivity;
  final CatalogStore catalog;
  final OperationQueue queue;

  bool downloading = false;

  /// Se llama al terminar init (main arranca la sincronizacion).
  void Function()? onReady;
  String? catalogError;

  /// Puede operar sin conexion: permiso del rol y funcion del plan (CU57).
  bool get canOperateOffline => auth.hasPermissions(['sync.run']) && auth.hasFeature('offline');

  Future<void> init() async {
    final me = auth.me;
    if (me == null) return;
    await catalog.ensureOwner(me.id, me.tenant?.id);
    await queue.refresh();
    if (canOperateOffline && connectivity.online && (catalog.info == null || catalog.stale)) {
      await downloadCatalog();
    }
    onReady?.call();
  }

  Future<bool> downloadCatalog() async {
    downloading = true;
    catalogError = null;
    notifyListeners();
    try {
      await catalog.download();
      return true;
    } on ApiError catch (e) {
      catalogError = 'No se pudo descargar el catálogo: ${e.message}';
      return false;
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  /// Operaciones que se perderian al cerrar sesion (sin resultado definitivo del servidor).
  int get unsynced => queue.operations.where((o) => OpStatus.outbox.contains(o.status)).length;
}
