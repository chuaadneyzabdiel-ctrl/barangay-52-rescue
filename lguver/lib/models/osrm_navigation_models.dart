import 'package:latlong2/latlong.dart';

/// One OSRM leg step (turn-by-turn).
class OsrmNavigationStep {
  final double distanceMeters;
  final double durationSeconds;
  final String? streetName;
  final String maneuverType;
  final String? modifier;
  final LatLng? maneuverLocation;
  final String instructionText;

  const OsrmNavigationStep({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.streetName,
    required this.maneuverType,
    required this.modifier,
    required this.maneuverLocation,
    required this.instructionText,
  });

  factory OsrmNavigationStep.fromOsrmJson(Map<String, dynamic> json) {
    final maneuver = json['maneuver'] as Map<String, dynamic>?;
    final name = json['name'] as String?;
    final type = maneuver?['type'] as String? ?? 'continue';
    final mod = maneuver?['modifier'] as String?;
    LatLng? loc;
    final locRaw = maneuver?['location'];
    if (locRaw is List && locRaw.length >= 2) {
      loc = LatLng(
        (locRaw[1] as num).toDouble(),
        (locRaw[0] as num).toDouble(),
      );
    }
    return OsrmNavigationStep(
      distanceMeters: (json['distance'] as num?)?.toDouble() ?? 0,
      durationSeconds: (json['duration'] as num?)?.toDouble() ?? 0,
      streetName: name?.isEmpty == true ? null : name,
      maneuverType: type,
      modifier: mod,
      maneuverLocation: loc,
      instructionText: _buildInstruction(type, mod, name),
    );
  }
}

String _buildInstruction(String type, String? mod, String? street) {
  final s = (street != null && street.isNotEmpty) ? ' onto $street' : '';
  switch (type) {
    case 'depart':
      return 'Head out$s';
    case 'arrive':
      return 'Arrive at destination';
    case 'roundabout':
    case 'rotary':
      return 'Enter roundabout$s';
    case 'roundabout turn':
      return 'At the roundabout$s';
    case 'fork':
      return 'At the fork, keep ${mod ?? 'straight'}$s';
    case 'merge':
      return 'Merge$s';
    case 'off ramp':
      return 'Take exit$s';
    case 'on ramp':
      return 'Take ramp$s';
    case 'end of road':
      return '${_modVerb(mod)} at end of road$s';
    case 'turn':
    case 'new name':
    case 'continue':
      return '${_modVerb(mod)}$s';
    default:
      return 'Continue$s';
  }
}

String _modVerb(String? mod) {
  if (mod == null || mod.isEmpty) return 'Continue';
  switch (mod) {
    case 'uturn':
      return 'Make a U-turn';
    case 'sharp left':
      return 'Turn sharp left';
    case 'slight left':
      return 'Turn slight left';
    case 'left':
      return 'Turn left';
    case 'sharp right':
      return 'Turn sharp right';
    case 'slight right':
      return 'Turn slight right';
    case 'right':
      return 'Turn right';
    case 'straight':
      return 'Continue straight';
    default:
      return 'Continue (${mod.replaceAll('_', ' ')})';
  }
}

/// Next-turn style guidance for the responder banner.
class NavigationGuidance {
  final String nextInstruction;
  final String distanceToNextLabel;
  final double distanceToNextManeuverKm;

  const NavigationGuidance({
    required this.nextInstruction,
    required this.distanceToNextLabel,
    required this.distanceToNextManeuverKm,
  });
}
