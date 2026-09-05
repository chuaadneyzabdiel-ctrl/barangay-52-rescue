/// Operational status for a response unit (`users/{unitId}/responseUnitStatus`).
///
/// Login lock on `unit_accounts/{id}/status` is separate (`active` / `disabled`).
/// Legacy RTDB value `active` on the operational field is treated as [inService].
enum ResponseUnitStatus {
  inService,
  outOfService,
  underMaintenance,
  disabled,
}

ResponseUnitStatus parseResponseUnitStatus(String? raw) {
  final v = (raw ?? '').trim().toLowerCase().replaceAll('-', '').replaceAll('_', '');
  switch (v) {
    case 'outofservice':
      return ResponseUnitStatus.outOfService;
    case 'undermaintenance':
    case 'maintenance':
      return ResponseUnitStatus.underMaintenance;
    case 'disabled':
      return ResponseUnitStatus.disabled;
    case 'active':
    case 'inservice':
    case '':
      return ResponseUnitStatus.inService;
    default:
      return ResponseUnitStatus.inService;
  }
}

/// Login lock on `unit_accounts/{id}/status`. Only `disabled` blocks sign-in.
bool unitLoginIsDisabled(String? raw) {
  return (raw ?? '').trim().toLowerCase() == 'disabled';
}

/// Operational status on `users/{unitId}`.
///
/// If no user row exists yet, treat as [ResponseUnitStatus.inService] (legacy
/// units that predate Account Center statuses).
/// If `responseUnitStatus` is missing: `approvedByLgu == true` → in service,
/// otherwise out of service until LGU sets In service.
ResponseUnitStatus responseUnitStatusFromUser(Map? user) {
  if (user == null) return ResponseUnitStatus.inService;
  final raw = user['responseUnitStatus']?.toString().trim();
  if (raw != null && raw.isNotEmpty) {
    return parseResponseUnitStatus(raw);
  }
  if (user['approvedByLgu'] == true) return ResponseUnitStatus.inService;
  // Explicit user row without approval/status → wait for LGU In service.
  if (user.containsKey('approvedByLgu') || user.containsKey('role')) {
    return ResponseUnitStatus.outOfService;
  }
  return ResponseUnitStatus.inService;
}

extension ResponseUnitStatusX on ResponseUnitStatus {
  /// Stored in Firebase.
  String get wireName {
    switch (this) {
      case ResponseUnitStatus.inService:
        return 'inService';
      case ResponseUnitStatus.outOfService:
        return 'outOfService';
      case ResponseUnitStatus.underMaintenance:
        return 'underMaintenance';
      case ResponseUnitStatus.disabled:
        return 'disabled';
    }
  }

  String get label {
    switch (this) {
      case ResponseUnitStatus.inService:
        return 'In service';
      case ResponseUnitStatus.outOfService:
        return 'Out of service';
      case ResponseUnitStatus.underMaintenance:
        return 'Under maintenance';
      case ResponseUnitStatus.disabled:
        return 'Disabled';
    }
  }

  bool get canSignIn => this != ResponseUnitStatus.disabled;

  bool get canTakeSos => this == ResponseUnitStatus.inService;

  String get signInBlockedMessage =>
      'This response unit is disabled and cannot sign in.';

  String get cannotTakeSosMessage {
    switch (this) {
      case ResponseUnitStatus.outOfService:
        return 'This unit is out of service.';
      case ResponseUnitStatus.underMaintenance:
        return 'This unit is under maintenance.';
      case ResponseUnitStatus.disabled:
        return 'This response unit is disabled.';
      case ResponseUnitStatus.inService:
        return '';
    }
  }
}
