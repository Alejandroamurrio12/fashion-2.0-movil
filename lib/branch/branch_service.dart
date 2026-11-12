import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../core/api_client.dart';
import '../core/api_error.dart';
import '../core/secure_store.dart';

class WorkBranch {
  const WorkBranch({required this.id, required this.name, this.city, this.address});

  final int id;
  final String name;
  final String? city;
  final String? address;

  factory WorkBranch.fromJson(Map<String, dynamic> j) =>
      WorkBranch(id: j['id'] as int, name: j['name'] as String, city: j['city'] as String?, address: j['address'] as String?);
}

/// Sucursal de trabajo (GET /branches/mine): activas y autorizadas; el personal solo las
/// asignadas (CU08). Sin conexion usa las del catalogo descargado ([offlineBranches]).
/// La eleccion se recuerda por usuario; el backend valida la sucursal en cada operacion.
class BranchService extends ChangeNotifier {
  BranchService(this.api, this.auth, this.store);

  final ApiClient api;
  final AuthService auth;
  final SecureStore store;

  /// Fuente sin conexion (la registra el catalogo offline en M2).
  Future<List<WorkBranch>> Function()? offlineBranches;

  List<WorkBranch> branches = const [];
  WorkBranch? selected;
  bool loaded = false;
  String? error;
  int? _loadedFor;

  String get _key => 'fashionstore.branch.${auth.me?.id ?? 'anon'}';

  Future<void> load({bool force = false}) async {
    final userId = auth.me?.id;
    if (loaded && !force && _loadedFor == userId) return;
    error = null;
    try {
      final rows = await api.get('/branches/mine') as List;
      branches = [for (final r in rows) WorkBranch.fromJson(r as Map<String, dynamic>)];
    } on ApiError catch (e) {
      if (e.isNetwork && offlineBranches != null) {
        branches = await offlineBranches!();
      } else {
        error = e.message;
        branches = const [];
      }
    }
    _loadedFor = userId;
    loaded = true;
    final stored = int.tryParse(await store.read(_key) ?? '');
    selected = branches.where((b) => b.id == stored).firstOrNull ?? branches.firstOrNull;
    if (selected != null) await store.write(_key, '${selected!.id}');
    notifyListeners();
  }

  Future<void> select(WorkBranch branch) async {
    selected = branch;
    await store.write(_key, '${branch.id}');
    notifyListeners();
  }

  void reset() {
    branches = const [];
    selected = null;
    loaded = false;
    _loadedFor = null;
    notifyListeners();
  }
}
