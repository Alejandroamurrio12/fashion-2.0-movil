import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'auth/auth_service.dart';
import 'sales/pos_screen.dart';
import 'sync/conflicts_screen.dart';
import 'sync/operations_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

/// Pantallas de la app (cada fase agrega las suyas).
final Map<String, WidgetBuilder> appRoutes = {
  '/pos': (_) => const PosScreen(),
  '/operations': (_) => const OperationsScreen(),
  '/conflicts': (_) => const ConflictsScreen(),
};

/// Raiz de la app: login o inicio segun la sesion.
class FashionStoreApp extends StatelessWidget {
  const FashionStoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FashionStore',
      debugShowCheckedModeBanner: false,
      locale: const Locale('es', 'BO'),
      supportedLocales: const [Locale('es', 'BO'), Locale('es')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(colorSchemeSeed: const Color(0xFF7A2E5C), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF7A2E5C), brightness: Brightness.dark, useMaterial3: true),
      routes: appRoutes,
      home: Consumer<AuthService>(
        builder: (context, auth, _) => auth.isAuthenticated ? const HomeScreen() : const LoginScreen(),
      ),
    );
  }
}
