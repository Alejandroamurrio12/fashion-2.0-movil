/// Error normalizado del backend: {"error": {"code", "message", "details"}}.
class ApiError implements Exception {
  ApiError({required this.status, required this.code, required this.message, this.details});

  final int status;
  final String code;
  final String message;
  final Object? details;

  bool get isNetwork => code == 'NETWORK_ERROR';

  /// Errores de validacion por campo (422 VALIDATION_ERROR).
  List<({String field, String message})> get fieldErrors {
    final d = details;
    if (code != 'VALIDATION_ERROR' || d is! List) return const [];
    return [
      for (final e in d)
        if (e is Map && e['field'] is String) (field: e['field'] as String, message: '${e['message']}'),
    ];
  }

  factory ApiError.network() =>
      ApiError(status: 0, code: 'NETWORK_ERROR', message: messageFor('NETWORK_ERROR')!);

  /// Arma el error a partir de la respuesta del backend (cuerpo JSON ya decodificado o null).
  factory ApiError.fromResponse(int status, Object? body) {
    if (body is Map && body['error'] is Map) {
      final e = body['error'] as Map;
      final code = '${e['code']}';
      final details = e['details'];
      return ApiError(
        status: status,
        code: code,
        message: messageFor(code, details) ?? (e['message'] as String?) ?? 'Ocurrió un error inesperado.',
        details: details,
      );
    }
    return ApiError(status: status, code: 'HTTP_ERROR', message: 'Ocurrió un error inesperado en el servidor.');
  }

  @override
  String toString() => 'ApiError($status, $code)';
}

/// Mensajes con redaccion para el usuario (el backend responde varios sin tildes).
String? messageFor(String code, [Object? details]) {
  final d = details is Map ? details : const {};
  switch (code) {
    case 'INSUFFICIENT_STOCK':
      return d.containsKey('available')
          ? 'Existencia insuficiente: hay ${d['available']} disponibles y se solicitaron ${d['requested']}.'
          : 'Existencia insuficiente.';
    case 'INSUFFICIENT_PAYMENT':
      return d.containsKey('total')
          ? 'El efectivo recibido (Bs ${_money(d['received'])}) no cubre el total (Bs ${_money(d['total'])}).'
          : 'El efectivo recibido no cubre el total.';
    case 'EXCHANGE_QUANTITY_EXCEEDED':
      return d.containsKey('available')
          ? 'Solo quedan ${d['available']} unidades de esa prenda por cambiar.'
          : 'La cantidad supera lo que queda por cambiar de esa prenda.';
  }
  return _messages[code];
}

String _money(Object? v) => (v is num ? v : num.tryParse('$v') ?? 0).toStringAsFixed(2);

const _messages = <String, String>{
  'NETWORK_ERROR': 'No se pudo conectar con el servidor. Verifique su conexión a internet.',
  'INVALID_CREDENTIALS': 'Credenciales inválidas. Verifique su correo y contraseña.',
  'TENANT_SUSPENDED': 'La empresa está suspendida. Comuníquese con el administrador de la plataforma.',
  'USER_INACTIVE': 'Su usuario está inactivo. Comuníquese con el administrador de su empresa.',
  'INVALID_REFRESH_TOKEN': 'Su sesión expiró. Inicie sesión nuevamente.',
  'SUBSCRIPTION_NOT_CURRENT': 'La suscripción no está vigente: la empresa está en modo solo lectura.',
  'PERMISSION_DENIED': 'No tiene permiso para realizar esta acción.',
  'FEATURE_NOT_IN_PLAN': 'Su plan actual no incluye esta funcionalidad.',
  'VALIDATION_ERROR': 'Hay datos inválidos. Revise los campos marcados.',
  'NOT_FOUND': 'El registro no existe o no está disponible.',
  'BRANCH_INACTIVE': 'La sucursal está inactiva: no admite operaciones.',
  'BRANCH_NOT_AUTHORIZED': 'No está asignado a esta sucursal.',
  'VARIANT_NOT_SELLABLE': 'Hay productos o variantes desactivados en la venta. Quítelos para continuar.',
  'INVALID_CUSTOMER': 'El cliente indicado no es un cliente activo de la empresa.',
  'CUSTOMER_REQUIRED': 'Indique el cliente de la reserva.',
  'RESERVATION_NOT_OPEN': 'La reserva ya no está abierta (fue entregada, cancelada o venció).',
  'RESERVATION_BRANCH_MISMATCH': 'La reserva es de otra sucursal: entréguela en la sucursal donde se hizo.',
  'RESERVATION_EXPIRED': 'La reserva venció y su stock fue liberado.',
  'SALE_NOT_EXCHANGEABLE': 'La venta no está confirmada: no admite cambios.',
  'EXCHANGE_PERIOD_EXPIRED': 'El plazo para cambiar prendas de esta venta ya venció.',
  'SAME_VARIANT': 'La prenda nueva debe ser distinta de la devuelta.',
  'OFFLINE_PAYMENT_NOT_CASH': 'Sin conexión solo se aceptan ventas al contado en efectivo.',
  'PAYLOAD_MISMATCH': 'La operación ya se había enviado con otro contenido; se rechazó para no duplicarla.',
  'SALE_NOT_FOUND': 'La venta indicada para el cambio no existe en el servidor.',
  'PRICE_CHANGED': 'El precio cobrado sin conexión difiere del vigente; la venta se confirmó con el precio cobrado.',
  'INTERNAL_ERROR': 'Error temporal del servidor; se reintentará.',
};
