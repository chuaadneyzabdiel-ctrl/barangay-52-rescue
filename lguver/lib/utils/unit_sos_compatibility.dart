import '../models/rescue_models.dart';

bool canUnitHandleSos(UnitType unitType, SOSType sosType) {
  switch (unitType) {
    case UnitType.ambulance:
      return sosType == SOSType.medical || sosType == SOSType.accident;
    case UnitType.fireTruck:
      return sosType == SOSType.fire ||
          sosType == SOSType.flood ||
          sosType == SOSType.accident;
    case UnitType.policeUnit:
      return sosType == SOSType.violence ||
          sosType == SOSType.accident ||
          sosType == SOSType.other;
    case UnitType.rescue:
      return sosType == SOSType.flood ||
          sosType == SOSType.violence ||
          sosType == SOSType.other ||
          sosType == SOSType.accident;
  }
}

String unitTypeLabel(UnitType unitType) {
  return switch (unitType) {
    UnitType.ambulance => 'Ambulance',
    UnitType.fireTruck => 'Fire truck',
    UnitType.policeUnit => 'Police',
    UnitType.rescue => 'Rescue/Tanod',
  };
}
