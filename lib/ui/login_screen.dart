import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_service.dart';
import '../core/api_error.dart';
import '../core/connectivity_service.dart';

const _reasons = {'expired': 'Su sesión expiró. Inicie sesión nuevamente.'};

/// CU58 Inicio de sesion.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthService>().login(_email.text.trim(), _password.text);
    } on ApiError catch (e) {
      _password.clear();
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final online = context.watch<ConnectivityService>().online;
    final reason = auth.endReason;
    final notice = reason == null ? null : (_reasons[reason] ?? messageFor(reason));
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('FashionStore',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text('Ventas en tienda, con y sin conexión', textAlign: TextAlign.center),
                    const SizedBox(height: 32),
                    if (notice != null) _Banner(key: const Key('login-notice'), text: notice, color: scheme.tertiaryContainer),
                    if (!online)
                      _Banner(text: 'Sin conexión: para iniciar sesión se necesita internet.', color: scheme.tertiaryContainer),
                    if (_error != null) _Banner(key: const Key('login-error'), text: _error!, color: scheme.errorContainer),
                    TextFormField(
                      key: const Key('email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Correo electrónico', border: OutlineInputBorder()),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        if (value.isEmpty) return 'Ingrese su correo.';
                        if (!_emailPattern.hasMatch(value)) return 'Ingrese un correo válido.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('password'),
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder()),
                      validator: (v) => (v ?? '').isEmpty ? 'Ingrese su contraseña.' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('login-button'),
                      onPressed: _busy ? null : _submit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_busy ? 'Ingresando…' : 'Ingresar'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Text(text),
      );
}
