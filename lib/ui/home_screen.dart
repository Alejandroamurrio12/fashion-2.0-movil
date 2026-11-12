import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../auth/models.dart';
import '../branch/branch_service.dart';
import '../core/connectivity_service.dart';
import '../offline/catalog_store.dart';
import '../offline/offline_bootstrap.dart';
import '../offline/operation_queue.dart';
import 'format.dart';
import 'nav.dart';

/// Inicio: empresa, plan, sucursal de trabajo, estado de conexion y menu segun rol y plan.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // primero la base local (sucursales offline), despues la sucursal de trabajo
      await context.read<OfflineBootstrap>().init();
      if (mounted) await context.read<BranchService>().load();
    });
  }

  /// Cierra sesion borrando los datos locales (RNF16); si quedan operaciones sin
  /// sincronizar, pide confirmacion porque se perderian (RN-08).
  Future<void> _logout() async {
    final pending = context.read<OfflineBootstrap>().unsynced;
    if (pending > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Operaciones sin sincronizar'),
          content: Text('Hay $pending operaciones sin sincronizar en este teléfono. Si cierra sesión se perderán.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            TextButton(key: const Key('confirm-logout'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Cerrar sesión')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (mounted) await context.read<AuthService>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final branches = context.watch<BranchService>();
    final online = context.watch<ConnectivityService>().online;
    final queue = context.watch<OperationQueue>();
    final me = auth.me!;
    final sub = me.subscription;
    final entries = visibleEntries(navEntries, auth);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(me.tenant?.legalName ?? 'FashionStore'),
        actions: [
          if (queue.pending > 0 || queue.conflicts > 0)
            TextButton(
              key: const Key('pending-badge'),
              onPressed: () => Navigator.of(context).pushNamed('/operations'),
              child: Text(queue.conflicts > 0 ? '${queue.pending} pend. · ${queue.conflicts} confl.' : '${queue.pending} sin sincronizar'),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              key: const Key('connection'),
              avatar: Icon(online ? Icons.cloud_done : Icons.cloud_off, size: 18),
              label: Text(online ? 'En línea' : 'Sin conexión'),
            ),
          ),
          IconButton(key: const Key('logout'), tooltip: 'Cerrar sesión', icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (auth.readOnly)
            Card(
              key: const Key('read-only'),
              color: scheme.tertiaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('La suscripción de su empresa no está vigente. Puede consultar, pero no registrar operaciones.'),
              ),
            ),
          Card(
            child: ListTile(
              title: Text(me.fullName),
              subtitle: Text(roleLabels[me.role] ?? me.role),
              trailing: sub == null ? null : Chip(label: Text('Plan ${sub.planName}')),
            ),
          ),
          if (sub != null)
            Card(
              child: ListTile(
                title: Text(sub.isCurrent ? 'Suscripción vigente' : 'Suscripción no vigente'),
                subtitle: Text('Vence el ${DateFormat('dd/MM/yyyy').format(DateTime.parse(sub.endDate))}'
                    '${sub.isCurrent ? ' · ${sub.daysRemaining} días' : ''}'),
              ),
            ),
          const SizedBox(height: 8),
          _BranchPicker(branches: branches),
          const SizedBox(height: 8),
          const _CatalogCard(),
          const SizedBox(height: 16),
          for (final e in entries)
            Card(
              child: ListTile(
                leading: Icon(e.icon),
                title: Text(e.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(e.route),
              ),
            ),
        ],
      ),
    );
  }
}

class _BranchPicker extends StatelessWidget {
  const _BranchPicker({required this.branches});

  final BranchService branches;

  @override
  Widget build(BuildContext context) {
    if (!branches.loaded) return const LinearProgressIndicator();
    if (branches.error != null) return Text(branches.error!, key: const Key('branch-error'));
    if (branches.branches.isEmpty) {
      return const Text(
        'No tiene sucursales activas asignadas. Pida al administrador de su empresa que lo asigne a una sucursal.',
        key: Key('no-branches'),
      );
    }
    return DropdownButtonFormField<int>(
      key: const Key('branch-picker'),
      initialValue: branches.selected?.id,
      decoration: const InputDecoration(labelText: 'Sucursal de trabajo', border: OutlineInputBorder()),
      items: [for (final b in branches.branches) DropdownMenuItem(value: b.id, child: Text(b.name))],
      onChanged: (id) {
        final b = branches.branches.firstWhere((x) => x.id == id);
        branches.select(b);
      },
    );
  }
}

/// Estado del catalogo descargado (CU59): fecha, desactualizado y boton para actualizar.
class _CatalogCard extends StatelessWidget {
  const _CatalogCard();

  @override
  Widget build(BuildContext context) {
    final boot = context.watch<OfflineBootstrap>();
    final catalog = context.watch<CatalogStore>();
    final online = context.watch<ConnectivityService>().online;
    if (!boot.canOperateOffline) return const SizedBox.shrink();
    final info = catalog.info;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('catalog-card'),
      color: info == null || catalog.stale ? scheme.tertiaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Catálogo para vender sin conexión', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              info == null
                  ? 'Todavía no se descargó: sin él no se puede vender sin conexión.'
                  : '${info.products} productos · generado ${dateTime(info.generatedAt.toIso8601String())}'
                      '${catalog.stale ? ' · desactualizado' : ''}',
              key: const Key('catalog-status'),
            ),
            if (boot.catalogError != null) Text(boot.catalogError!, style: TextStyle(color: scheme.error)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('update-catalog'),
                onPressed: online && !boot.downloading ? boot.downloadCatalog : null,
                child: Text(boot.downloading ? 'Descargando…' : 'Actualizar catálogo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
