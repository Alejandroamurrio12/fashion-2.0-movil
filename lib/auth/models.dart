/// Contrato de /auth/login, /auth/refresh y /auth/me (app/schemas/auth.py del backend).
class TenantInfo {
  TenantInfo({required this.id, required this.legalName, required this.status});

  final int id;
  final String legalName;
  final String status;

  factory TenantInfo.fromJson(Map<String, dynamic> j) =>
      TenantInfo(id: j['id'] as int, legalName: j['legal_name'] as String, status: j['status'] as String);

  Map<String, dynamic> toJson() => {'id': id, 'legal_name': legalName, 'status': status};
}

class SubscriptionInfo {
  SubscriptionInfo({
    required this.planCode,
    required this.planName,
    required this.status,
    required this.endDate,
    required this.isCurrent,
    required this.daysRemaining,
    required this.maxActiveBranches,
    required this.features,
  });

  final String planCode;
  final String planName;
  final String status;
  final String endDate;
  final bool isCurrent;
  final int daysRemaining;
  final int maxActiveBranches;
  final Map<String, bool> features;

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) => SubscriptionInfo(
        planCode: j['plan_code'] as String,
        planName: j['plan_name'] as String,
        status: j['status'] as String,
        endDate: j['end_date'] as String,
        isCurrent: j['is_current'] as bool,
        daysRemaining: j['days_remaining'] as int,
        maxActiveBranches: j['max_active_branches'] as int,
        features: (j['features'] as Map).map((k, v) => MapEntry('$k', v == true)),
      );

  Map<String, dynamic> toJson() => {
        'plan_code': planCode,
        'plan_name': planName,
        'status': status,
        'end_date': endDate,
        'is_current': isCurrent,
        'days_remaining': daysRemaining,
        'max_active_branches': maxActiveBranches,
        'features': features,
      };
}

class Me {
  Me({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.permissions,
    required this.isPlatformAdmin,
    required this.readOnly,
    this.tenant,
    this.subscription,
  });

  final int id;
  final String email;
  final String fullName;
  final String role;
  final List<String> permissions;
  final bool isPlatformAdmin;
  final bool readOnly;
  final TenantInfo? tenant;
  final SubscriptionInfo? subscription;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as int,
        email: j['email'] as String,
        fullName: j['full_name'] as String,
        role: j['role'] as String,
        permissions: [for (final p in j['permissions'] as List) '$p'],
        isPlatformAdmin: j['is_platform_admin'] as bool,
        readOnly: j['read_only'] as bool,
        tenant: j['tenant'] == null ? null : TenantInfo.fromJson(j['tenant'] as Map<String, dynamic>),
        subscription:
            j['subscription'] == null ? null : SubscriptionInfo.fromJson(j['subscription'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'full_name': fullName,
        'role': role,
        'permissions': permissions,
        'is_platform_admin': isPlatformAdmin,
        'read_only': readOnly,
        'tenant': tenant?.toJson(),
        'subscription': subscription?.toJson(),
      };
}

const roleLabels = {
  'ADMIN_PLATAFORMA': 'Administrador de plataforma',
  'ADMINISTRADOR': 'Administrador',
  'ENCARGADO': 'Encargado de sucursal',
  'CAJERO': 'Cajero',
  'CLIENTE': 'Cliente',
};
