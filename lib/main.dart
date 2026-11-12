import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'auth/auth_service.dart';
import 'branch/branch_service.dart';
import 'core/api_client.dart';
import 'core/connectivity_service.dart';
import 'core/secure_store.dart';
import 'offline/catalog_store.dart';
import 'offline/local_db.dart';
import 'offline/offline_bootstrap.dart';
import 'offline/operation_queue.dart';
import 'offline/sync_service.dart';
import 'sales/sale_cart.dart';
import 'store/cart.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es_BO');

  const store = DeviceSecureStore();
  final api = ApiClient();
  final auth = AuthService(api, store);
  final connectivity = ConnectivityService();
  final local = await LocalDb.open();
  final services = AppServices.wire(api: api, auth: auth, store: store, connectivity: connectivity, local: local);

  await connectivity.check();
  await auth.restore();

  runApp(services.provide(const FashionStoreApp()));
}

/// Servicios de la app y sus dependencias (main y pruebas los arman igual).
class AppServices {
  AppServices._(this.api, this.auth, this.connectivity, this.branches, this.catalog, this.queue, this.bootstrap, this.sync, this.cart, this.saleCart);

  final ApiClient api;
  final AuthService auth;
  final ConnectivityService connectivity;
  final BranchService branches;
  final CatalogStore catalog;
  final OperationQueue queue;
  final OfflineBootstrap bootstrap;
  final SyncService sync;
  final CartService cart;
  final SaleCart saleCart;

  factory AppServices.wire({
    required ApiClient api,
    required AuthService auth,
    required SecureStore store,
    required ConnectivityService connectivity,
    required LocalDb local,
    Duration? syncInterval = const Duration(seconds: 30),
  }) {
    final branches = BranchService(api, auth, store);
    final catalog = CatalogStore(local, api);
    final queue = OperationQueue(local);
    final bootstrap = OfflineBootstrap(auth, connectivity, catalog, queue);
    final sync = SyncService(api, auth, connectivity, queue, interval: syncInterval);
    final cart = CartService(api);
    final saleCart = SaleCart();
    // la cola se empieza a enviar cuando el usuario puede operar sin conexion
    bootstrap.onReady = () {
      if (bootstrap.canOperateOffline) sync.start();
    };
    // sin conexion, la sucursal de trabajo sale del catalogo descargado
    branches.offlineBranches = catalog.branches;
    // al cerrar sesion se borran los datos locales (RNF16)
    auth.onLogout.add(() async {
      sync.stop();
      await catalog.clear();
      await queue.refresh();
      branches.reset();
      cart.reset();
      saleCart.clear();
    });
    return AppServices._(api, auth, connectivity, branches, catalog, queue, bootstrap, sync, cart, saleCart);
  }

  Widget provide(Widget child) => MultiProvider(
        providers: [
          Provider.value(value: api),
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: connectivity),
          ChangeNotifierProvider.value(value: branches),
          ChangeNotifierProvider.value(value: catalog),
          ChangeNotifierProvider.value(value: queue),
          ChangeNotifierProvider.value(value: bootstrap),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: cart),
          ChangeNotifierProvider.value(value: saleCart),
        ],
        child: child,
      );
}
