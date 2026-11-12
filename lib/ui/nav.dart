import 'package:flutter/material.dart';

import '../auth/auth_service.dart';

/// Entrada del menu. Se muestra si el rol tiene los permisos (todos, o alguno de [anyPermissions])
/// y el plan habilita la funcion. Solo se listan pantallas implementadas; cada fase agrega las suyas.
class NavEntry {
  const NavEntry({
    required this.label,
    required this.icon,
    required this.route,
    this.permissions = const [],
    this.anyPermissions = const [],
    this.feature,
  });

  final String label;
  final IconData icon;
  final String route;
  final List<String> permissions;
  final List<String> anyPermissions;
  final String? feature;
}

const List<NavEntry> navEntries = [
  NavEntry(label: 'Catálogo', icon: Icons.grid_view, route: '/catalog', permissions: ['sales.create'], feature: 'sales'),
  NavEntry(label: 'Punto de venta', icon: Icons.point_of_sale, route: '/pos', permissions: ['sales.create'], feature: 'sales'),
  NavEntry(label: 'Operaciones sin conexión', icon: Icons.sync, route: '/operations', permissions: ['sync.run'], feature: 'offline'),
  NavEntry(label: 'Conflictos de sincronización', icon: Icons.rule, route: '/conflicts', permissions: ['sync.resolve_conflicts']),
];

List<NavEntry> visibleEntries(List<NavEntry> entries, AuthService auth) => [
      for (final e in entries)
        if (auth.hasPermissions(e.permissions) &&
            (e.anyPermissions.isEmpty || auth.hasAnyPermission(e.anyPermissions)) &&
            (e.feature == null || auth.hasFeature(e.feature!)))
          e,
    ];
