import 'package:latlong2/latlong.dart';
import '../models/map_layer_models.dart';

/// Emergency map layer POIs.
/// Hospital/clinic coordinates are from OpenStreetMap Nominatim, Wikipedia,
/// and official listings (2026). 3S pins use the barangay hall / health
/// station, not the city-center fallback.
class MapLayerDataService {
  static const _center = LatLng(14.6488536, 120.9906085); // Caloocan City Hall

  static List<MapLayerPOI> getLayerData(MapLayerType type) {
    switch (type) {
      case MapLayerType.evacuationRoutes:
        return _evacuationRoutes();
      case MapLayerType.hospitals:
        return _hospitals();
      case MapLayerType.threeSCenters:
        return _threeSCenters();
      case MapLayerType.policeStations:
        return _policeStations();
      case MapLayerType.fireStations:
        return _fireStations();
      case MapLayerType.evacuationCenters:
        return _evacuationCenters();
      case MapLayerType.floodProneAreas:
        return _floodProneAreas();
      case MapLayerType.landslideProneAreas:
        return _landslideProneAreas();
      case MapLayerType.roadBlockages:
        return _roadBlockages();
      case MapLayerType.trafficConditions:
        return _trafficConditions();
      case MapLayerType.safeZones:
        return _safeZones();
      case MapLayerType.emergencyHotlines:
        return _emergencyHotlines();
      case MapLayerType.incidentReports:
        return [];
      case MapLayerType.bridgeConditions:
        return _bridgeConditions();
      case MapLayerType.riverLevels:
        return _riverLevels();
      case MapLayerType.searchRescueLocations:
        return [];
      case MapLayerType.supplyPoints:
        return _supplyPoints();
      case MapLayerType.hazardZones:
        return [];
      case MapLayerType.gpsVictims:
        return [];
      case MapLayerType.weatherAlerts:
        return _weatherAlerts();
    }
  }

  static List<MapLayerPOI> _evacuationRoutes() {
    return [
      MapLayerPOI(
        id: 'evac-1',
        name: 'North Caloocan Evacuation Route',
        position: _center,
        layerType: MapLayerType.evacuationRoutes,
        polyline: [
          const LatLng(14.75, 121.02),
          const LatLng(14.72, 121.03),
          const LatLng(14.70, 121.02),
        ],
        subtitle: 'To Bagumbong Evac Center',
      ),
    ];
  }

  static List<MapLayerPOI> _hospitals() {
    final entries = <dynamic>[
      (city: 'Valenzuela', name: 'Acebedo General Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'General Luis St, Kaybiga', lat: 14.7188033, lng: 121.0051496),
      (city: 'Valenzuela', name: 'Baesa Advent Polyclinic and General Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Rivera Drive, Libis Baesa', lat: 14.6767411, lng: 121.0052375),
      (city: 'Caloocan', name: 'Dr. Jose N. Rodriguez Memorial Hospital and Sanitarium', type: 'hospital', ownership: 'public', emergency: true, open: 'Open 24 hours', isOpenNow: true, lat: 14.766534, lng: 121.0657354),
      (city: 'Caloocan', name: 'MCU–Filemon Dionisio Tanchoco Medical Foundation Hospital (MCU Hospital)', type: 'hospital', ownership: 'private', emergency: true, open: 'Open 24 hours', isOpenNow: true, lat: 14.657555, lng: 120.9871406),
      (city: 'Caloocan', name: 'North Caloocan Doctors Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Quirino Highway, Brgy 185', lat: 14.766024, lng: 121.0847039),
      (city: 'Caloocan', name: 'Our Lady of Grace Hospital', type: 'hospital', ownership: 'private', emergency: true, address: '8th Ave cor F. Roxas, Grace Park', lat: 14.6489426, lng: 120.9813796),
      (city: 'Caloocan', name: 'San Lorenzo General Hospital', type: 'hospital', ownership: 'private', emergency: true, address: '24 Susano Rd, Deparo', lat: 14.73727, lng: 121.0324),
      (city: 'Caloocan', name: 'Caloocan City Medical Center', type: 'hospital', ownership: 'public', emergency: true, open: 'Open 24 hours', isOpenNow: true, lat: 14.6483271, lng: 120.9736139),
      (city: 'Caloocan', name: 'Caloocan City North Medical Center', type: 'hospital', ownership: 'public', emergency: true, address: 'Thunderbird St, Camarin', open: 'Open 24 hours', isOpenNow: true, lat: 14.7561560, lng: 121.0502128),
      (city: 'Manila', name: 'Philippine General Hospital', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5771387, lng: 120.9851572),
      (city: 'Manila', name: 'Manila Doctors Hospital', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5819484, lng: 120.9829913),
      (city: 'Manila', name: 'Ospital ng Maynila Medical Center (Bagong Ospital ng Maynila)', type: 'hospital', ownership: 'public', emergency: true, address: '719 Quirino Ave, Malate', phone: '(02) 8524 6061', open: 'Open 24 hours', isOpenNow: true, lat: 14.5644562, lng: 120.9870002),
      (city: 'Manila', name: 'Tondo Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6348716, lng: 120.9630926),
      (city: 'Manila', name: 'Jose R. Reyes Memorial Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6143273, lng: 120.9822566),
      (city: 'Manila', name: 'University of Santo Tomas Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'España cor Lacson, Sampaloc', lat: 14.61095, lng: 120.99004),
      (city: 'Manila', name: 'Chinese General Hospital and Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: '286 Blumentritt St, Santa Cruz', lat: 14.626306, lng: 120.987780),
      (city: 'Manila', name: 'ManilaMed', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5825352, lng: 120.9856015),
      (city: 'Manila', name: 'Santa Ana Hospital', type: 'hospital', ownership: 'public', emergency: true, address: '2692 New Panaderos St', lat: 14.583335, lng: 121.016499),
      (city: 'Manila', name: 'San Lazaro Hospital', type: 'hospital', ownership: 'public', emergency: true, address: 'Quiricada St, Sta Cruz', open: 'Open 24 hours', isOpenNow: true, lat: 14.6136699, lng: 120.9808847),
      (city: 'Quezon City', name: 'United Doctors Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: '6 Nicanor Ramirez, Galas', phone: '(02) 8712 3640', open: 'Open 24 hours', isOpenNow: true, lat: 14.6171552, lng: 121.0018332),
      (city: 'Manila', name: 'Ospital ng Sampaloc', type: 'hospital', ownership: 'public', emergency: true, address: '677 Gen. Geronimo St', phone: '(02) 8749 0224', open: 'Open 24 hours', isOpenNow: true, lat: 14.6076187, lng: 120.9968061),
      (city: 'Manila', name: 'St. Clare’s Medical Center, Inc.', type: 'hospital', ownership: 'private', emergency: true, address: '1838 Dian St', phone: '(02) 8831 6512', open: 'Open 24 hours', isOpenNow: true, lat: 14.562984, lng: 121.0013004),
      (city: 'Manila', name: 'Metropolitan Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'Masangkay St, Tondo', lat: 14.6096313, lng: 120.9783605),
      (city: 'Manila', name: 'Esperanza Health Center', type: 'health_center', ownership: 'public', emergency: false, lat: 14.60051, lng: 121.012858),
      (city: 'Manila', name: 'F. Lanuza Health Center and Lying–in Clinic', type: 'lying_in', ownership: 'public', emergency: false, lat: 14.612504, lng: 120.9814928),
      (city: 'Manila', name: 'Pedro Gil Health Center and Lying–in Clinic', type: 'lying_in', ownership: 'public', emergency: false, lat: 14.5715455, lng: 121.0005443),
      (city: 'Manila', name: 'Victory Lying-In Center', type: 'lying_in', ownership: 'private', emergency: true, lat: 14.6227875, lng: 120.9891658),
      (city: 'Manila', name: 'The Queen’s Clinic - Manila Branch', type: 'ob_gyne', ownership: 'private', emergency: true, lat: 14.621921, lng: 121.00666),
      (city: 'Manila', name: 'The Medical City Clinic SM Manila', type: 'clinic', ownership: 'private', emergency: false, address: 'SM City Manila', open: 'Open now', isOpenNow: true, lat: 14.590108, lng: 120.983104),
      (city: 'Quezon City', name: 'East Avenue Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6421432, lng: 121.0479837),
      (city: 'Quezon City', name: 'Philippine Heart Center', type: 'hospital', ownership: 'public', emergency: true, address: 'East Avenue', lat: 14.64402, lng: 121.04842),
      (city: 'Quezon City', name: 'National Kidney and Transplant Institute', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6473447, lng: 121.0473288),
      (city: 'Quezon City', name: 'Lung Center of the Philippines', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6477279, lng: 121.0452136),
      (city: 'Quezon City', name: 'Capitol Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.6342467, lng: 121.0228414),
      (city: 'Quezon City', name: 'De Los Santos Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.6201181, lng: 121.0174251),
      (city: 'Quezon City', name: 'St. Luke\'s Medical Center – Quezon City', type: 'hospital', ownership: 'private', emergency: true, lat: 14.6225328, lng: 121.0232452),
      (city: 'Quezon City', name: 'Quezon City General Hospital', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6611599, lng: 121.018209),
      (city: 'Quezon City', name: 'Veterans Memorial Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6561184, lng: 121.0400556),
      (city: 'Quezon City', name: 'The Queen’s Clinic - Fairview Branch', type: 'ob_gyne', ownership: 'private', emergency: true, lat: 14.7337269, lng: 121.0525393),
      (city: 'Quezon City', name: 'World Citi Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: '960 Aurora Blvd', phone: '+63 2 8423 7100', open: 'Open 24 hours', isOpenNow: true, lat: 14.6269592, lng: 121.0633176),
      (city: 'Quezon City', name: 'Providence Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Quezon Ave', phone: '+63 2 8558 6999', open: 'Open 24 hours', isOpenNow: true, lat: 14.6412487, lng: 121.0316843),
      (city: 'Quezon City', name: 'Commonwealth Hospital and Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'Regalado Highway, Greater Lagro', phone: '+63 2 8930 0000', open: 'Open 24 hours', isOpenNow: true, lat: 14.7313887, lng: 121.0606405),
      (city: 'Quezon City', name: 'Diliman Doctors Hospital', type: 'hospital', ownership: 'private', emergency: true, address: '251 Commonwealth Ave', phone: '+63 2 8883 6900', open: 'Open 24 hours', isOpenNow: true, lat: 14.6685139, lng: 121.0762873),
      (city: 'Quezon City', name: 'New Era General Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Tandang Sora Ave', phone: '+63 2 8714 6344', open: 'Open 24 hours', isOpenNow: true, lat: 14.6641638, lng: 121.0667110),
      (city: 'Quezon City', name: 'Metro North Medical Center Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Mindanao Ave, Project 8', phone: '+63 2 8426 8000', open: 'Open 24 hours', isOpenNow: true, lat: 14.6689737, lng: 121.0337227),
      (city: 'Pasig', name: 'Rizal Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5632873, lng: 121.0660398),
      (city: 'Pasig', name: 'The Medical City – Ortigas', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5894434, lng: 121.0695113),
      (city: 'Pasig', name: 'Pasig City General Hospital', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5721964, lng: 121.0994306),
      (city: 'Pasig', name: 'Pasig Doctors Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'E. Rodriguez Ave', phone: '(02) 8878 7362', open: 'Open 24 hours', isOpenNow: true, lat: 14.6007047, lng: 121.0920985),
      (city: 'Pasig', name: 'Javillonar Clinic and Hospital', type: 'clinic', ownership: 'private', emergency: false, lat: 14.565355, lng: 121.0784561),
      (city: 'Makati', name: 'Makati Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5591862, lng: 121.014828),
      (city: 'Makati', name: 'Ospital ng Makati', type: 'hospital', ownership: 'public', emergency: true, address: 'Sampaguita St, Comembo', open: 'Open 24 hours', isOpenNow: true, lat: 14.5465072, lng: 121.0617567),
      (city: 'Makati', name: 'IntimaV Center by Dr. Jenny Jose', type: 'ob_gyne', ownership: 'private', emergency: false, lat: 14.5583718, lng: 121.0143519),
      (city: 'Taguig', name: 'St. Luke\'s Medical Center – Global City', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5550704, lng: 121.0482642),
      (city: 'Taguig', name: 'Taguig City General Hospital', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5143292, lng: 121.0727527),
      (city: 'Taguig', name: 'Taguig–Pateros District Hospital', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5108615, lng: 121.0343406),
      (city: 'Taguig', name: 'Kindred PH - BGC Branch', type: 'ob_gyne', ownership: 'private', emergency: false, address: '2F Serendra Mall, 11th Ave', lat: 14.5490742, lng: 121.0544856),
      (city: 'Pasay', name: 'San Juan de Dios Hospital', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5385542, lng: 120.9930502),
      (city: 'Pasay', name: 'Pasay City General Hospital', type: 'hospital', ownership: 'public', emergency: true, address: 'Padre Burgos St', lat: 14.5493199, lng: 121.0010011),
      (city: 'Pasay', name: 'Adventist Medical Center Manila', type: 'hospital', ownership: 'private', emergency: true, address: '1945 Donada St', open: 'Open 24 hours', isOpenNow: true, lat: 14.5557941, lng: 120.9955069),
      (city: 'Muntinlupa', name: 'Asian Hospital and Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.4134655, lng: 121.0435335),
      (city: 'Muntinlupa', name: 'Ospital ng Muntinlupa', type: 'hospital', ownership: 'public', emergency: true, lat: 14.4143419, lng: 121.0440011),
      (city: 'Muntinlupa', name: 'Alabang Medical Clinic–Muntinlupa Branch', type: 'clinic', ownership: 'private', emergency: false, lat: 14.390999, lng: 121.044445),
      (city: 'Muntinlupa', name: 'San Roque Medical Clinic', type: 'clinic', ownership: 'private', emergency: false, lat: 14.4193069, lng: 121.0470926),
      (city: 'Paranaque', name: 'Medical Center Paranaque', type: 'hospital', ownership: 'private', emergency: true, lat: 14.4582914, lng: 121.033451),
      (city: 'Paranaque', name: 'Ospital ng Parañaque', type: 'hospital', ownership: 'public', emergency: true, lat: 14.5004142, lng: 120.9911214),
      (city: 'Paranaque', name: 'Parañaque Doctors\' Hospital', type: 'hospital', ownership: 'private', emergency: true, lat: 14.485867, lng: 121.028415),
      (city: 'Paranaque', name: 'OPD OB-GYNE and Medical Clinic', type: 'ob_gyne', ownership: 'private', emergency: true, address: 'Quirino Ave, Baclaran', lat: 14.5316, lng: 120.9928),
      (city: 'Paranaque', name: 'Olivarez General Hospital', type: 'hospital', ownership: 'private', emergency: true, address: 'Dr Arcadio Santos Ave', phone: '(02) 8842 1644', open: 'Open 24 hours', isOpenNow: true, lat: 14.4792298, lng: 120.9968424),
      (city: 'Las Pinas', name: 'Las Piñas General Hospital and Satellite Trauma Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.4716706, lng: 120.973806),
      (city: 'Las Pinas', name: 'Perpetual Help Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'Alabang-Zapote Rd', lat: 14.4483273, lng: 120.9856363),
      (city: 'Las Pinas', name: 'HealthFort Lying-in and Clinic', type: 'lying_in', ownership: 'private', emergency: true, lat: 14.4266597, lng: 121.0126486),
      (city: 'Las Pinas', name: 'The Queen’s Clinic - Las Piñas Branch', type: 'ob_gyne', ownership: 'private', emergency: true, address: 'BF Resort Village, Talon Dos', lat: 14.4378, lng: 120.9985),
      (city: 'Mandaluyong', name: 'Mandaluyong City Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.582747, lng: 121.03664),
      (city: 'Mandaluyong', name: 'Victor R. Potenciano Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5770225, lng: 121.0500827),
      (city: 'Marikina', name: 'Amang Rodriguez Memorial Medical Center', type: 'hospital', ownership: 'public', emergency: true, lat: 14.6361206, lng: 121.0984332),
      (city: 'Marikina', name: 'Marikina Valley Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'Sumulong Highway', lat: 14.6349398, lng: 121.1039403),
      (city: 'Marikina', name: 'The Pink MDs Lying-in and Women\'s Clinic', type: 'lying_in', ownership: 'private', emergency: true, lat: 14.663857, lng: 121.1063544),
      (city: 'San Juan', name: 'Cardinal Santos Medical Center', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5977862, lng: 121.0455347),
      (city: 'Valenzuela', name: 'Valenzuela Medical Center (City General Hospital)', type: 'hospital', ownership: 'public', emergency: true, address: 'Padrigal St, Karuhatan', phone: '(02) 8294 6711', open: 'Open 24 hours', isOpenNow: true, lat: 14.6899682, lng: 120.9778414),
      (city: 'Valenzuela', name: 'Valenzuela City Emergency Hospital', type: 'hospital', ownership: 'public', emergency: true, address: 'G. Lazaro St, Dalandanan', open: 'Open 24 hours', isOpenNow: true, lat: 14.7091985, lng: 120.9581415),
      (city: 'Valenzuela', name: 'Fatima University Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'MacArthur Highway, Marulas', open: 'Open 24 hours', isOpenNow: true, lat: 14.6780788, lng: 120.9804708),
      (city: 'Valenzuela', name: 'Valenzuela Citicare Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: 'KM 14 MacArthur Hwy, Malinta', phone: '(02) 8860 9300', open: 'Open 24 hours', isOpenNow: true, lat: 14.6954025, lng: 120.9628609),
      (city: 'Valenzuela', name: 'J.F. Sanchez Medical & Lying-In Clinic', type: 'lying_in', ownership: 'private', emergency: true, address: '330 General Luis, Bagbaguin', phone: '0945 496 3322', open: 'Open 24 hours', isOpenNow: true, lat: 14.7138203, lng: 121.0009027),
      (city: 'Valenzuela', name: 'Canumay West Lying-In Clinic', type: 'lying_in', ownership: 'public', emergency: true, address: 'T. Santiago St, Brgy Hall', phone: '(02) 3445 2631', open: 'Open 24 hours', isOpenNow: true, lat: 14.7068493, lng: 120.9849606),
      (city: 'Valenzuela', name: 'St. Nathanielle Lying-In & Medical Clinic', type: 'lying_in', ownership: 'private', emergency: true, address: '182 Maysan Rd', phone: '0966 863 9905', open: 'Closed - Opens 1 PM', isOpenNow: false, lat: 14.6977439, lng: 120.9792343),
      (city: 'Valenzuela', name: 'Valenzuela City Lying-In Clinic - Marulas', type: 'lying_in', ownership: 'public', emergency: true, address: '42 Tamaraw Hills Ext', open: 'Open now', isOpenNow: true, lat: 14.6742692, lng: 120.9884980),
      (city: 'Valenzuela', name: 'Anna Marie Lying-In Clinic', type: 'lying_in', ownership: 'private', emergency: true, address: 'Maysan Rd', phone: '0905 329 6367', open: 'Closed - Opens 12 PM', isOpenNow: false, lat: 14.6970, lng: 120.9805),
      (city: 'Malabon', name: 'Ospital ng Malabon', type: 'hospital', ownership: 'public', emergency: true, address: 'F. Sevilla Blvd, Tañong', lat: 14.6571750, lng: 120.9505826),
      (city: 'Malabon', name: 'Malabon Hospital and Medical Center', type: 'hospital', ownership: 'private', emergency: true, address: '264 Gov. Pascual Ave', phone: '0927 672 5058', open: 'Open 24 hours', isOpenNow: true, lat: 14.670406, lng: 120.9554764),
      (city: 'Malabon', name: 'San Lorenzo Ruiz General Hospital', type: 'hospital', ownership: 'public', emergency: true, address: 'O. Reyes St, Panghulo', open: 'Open 24 hours', isOpenNow: true, lat: 14.6942908, lng: 120.9564064),
      (city: 'Navotas', name: 'Navotas City Hospital', type: 'hospital', ownership: 'public', emergency: true, address: 'M. Naval St', open: 'Open 24 hours', isOpenNow: true, lat: 14.6601295, lng: 120.9458638),
      (city: 'Pateros', name: 'ACE Medical Center – Pateros', type: 'hospital', ownership: 'private', emergency: true, lat: 14.5440787, lng: 121.0652003),
      (city: 'Caloocan', name: 'Bazarte Well Family Midlife Clinic', type: 'clinic', ownership: 'private', emergency: false, address: 'Camarin Rd, Brgy 178', lat: 14.7588, lng: 121.0445),
      (city: 'Caloocan', name: 'Jean Demegillo Maternity and Lying–in Clinic', type: 'lying_in', ownership: 'private', emergency: false, lat: 14.688173, lng: 121.0196623),
      (city: 'Caloocan', name: 'The Queen’s Clinic - Camarin Branch', type: 'ob_gyne', ownership: 'private', emergency: true, lat: 14.7505661, lng: 121.0448765),
      (city: 'Caloocan', name: 'Doña Aurora Obgyn-Clinic', type: 'ob_gyne', ownership: 'private', emergency: true, lat: 14.7495464, lng: 121.0578085),
      (city: 'Caloocan', name: 'Romerosa Lying-in Clinic', type: 'lying_in', ownership: 'private', emergency: true, address: 'Bagong Barrio, Caloocan', open: 'Open now', isOpenNow: true, lat: 14.664319, lng: 120.991305),
    ];

    return List<MapLayerPOI>.generate(entries.length, (i) {
      final dynamic e = entries[i];
      final city = (e.city as String?) ?? 'Metro Manila';
      final name = (e.name as String?) ?? 'Facility';
      final type = (e.type as String?) ?? 'hospital';
      final ownership = (e.ownership as String?) ?? 'private';
      final emergency = (e.emergency as bool?) ?? true;
      String? address;
      String? phone;
      String? open;
      bool? isOpenNow;
      double? lat;
      double? lng;
      try {
        address = e.address as String?;
      } catch (_) {}
      try {
        phone = e.phone as String?;
      } catch (_) {}
      try {
        open = e.open as String?;
      } catch (_) {}
      try {
        isOpenNow = e.isOpenNow as bool?;
      } catch (_) {}
      try {
        lat = (e.lat as num?)?.toDouble();
      } catch (_) {}
      try {
        lng = (e.lng as num?)?.toDouble();
      } catch (_) {}

      if (lat == null || lng == null) {
        return MapLayerPOI(
          id: 'mm-fac-skip-$i',
          name: name,
          position: const LatLng(0, 0),
          layerType: MapLayerType.hospitals,
        );
      }

      return MapLayerPOI(
        id: 'mm-fac-$i',
        name: name,
        position: LatLng(lat, lng),
        layerType: MapLayerType.hospitals,
        subtitle:
            '$city • $ownership • ${emergency ? "Emergency" : "Non-emergency"}',
        city: city,
        facilityType: type,
        ownership: ownership,
        emergencyCapable: emergency,
        address: address,
        phone: phone,
        openStatusText: open,
        isOpenNow: isOpenNow,
      );
    }).where((p) => p.position.latitude != 0 || p.position.longitude != 0).toList();
  }

  static List<MapLayerPOI> _threeSCenters() {
    final entries = <({String name, String city, double lat, double lng})>[
      (name: '3S Center Gen T. De Leon', city: 'Valenzuela', lat: 14.6859498, lng: 120.9956443),
      (name: '3S Center Marulas', city: 'Valenzuela', lat: 14.6742692, lng: 120.9884980),
      (name: '3S Center Ugong', city: 'Valenzuela', lat: 14.6951176, lng: 121.0111731),
      (name: '3S Center Karuhatan', city: 'Valenzuela', lat: 14.6895603, lng: 120.9784241),
      (name: '3S Center Parada', city: 'Valenzuela', lat: 14.6958364, lng: 120.9891996),
      (name: '3S Center Maysan', city: 'Valenzuela', lat: 14.6977439, lng: 120.9792343),
      (name: '3S Center Bagbaguin', city: 'Valenzuela', lat: 14.7138203, lng: 121.0009027),
      (name: '3S Center Mapulang Lupa', city: 'Valenzuela', lat: 14.7024834, lng: 121.0008118),
      (name: '3S Center Lawang Bato', city: 'Valenzuela', lat: 14.7300000, lng: 120.9932091),
      (name: '3S Center Canumay West', city: 'Valenzuela', lat: 14.7068493, lng: 120.9849606),
      (name: '3S Center Punturin', city: 'Valenzuela', lat: 14.7410552, lng: 120.9901967),
      (name: '3S Center Dalandanan', city: 'Valenzuela', lat: 14.7042439, lng: 120.9612208),
      (name: '3S Center Malabo, Maysan', city: 'Valenzuela', lat: 14.6955, lng: 120.9820),
      (name: '3S Center Malanday', city: 'Valenzuela', lat: 14.7158281, lng: 120.9537582),
      (name: '3S Center Balangkas', city: 'Valenzuela', lat: 14.7180, lng: 120.9480),
      (name: '3S Center Wawang Pulo', city: 'Valenzuela', lat: 14.7245, lng: 120.9370),
      (name: '3S Center Polo', city: 'Valenzuela', lat: 14.7081028, lng: 120.9477773),
      (name: '3S Center Pasolo', city: 'Valenzuela', lat: 14.7035, lng: 120.9410),
      (name: '3S Paso de Blas - New Building', city: 'Valenzuela', lat: 14.7077487, lng: 120.9924608),
      (name: '3S Center Canumay East', city: 'Valenzuela', lat: 14.7185, lng: 120.9925),
    ];
    return List<MapLayerPOI>.generate(entries.length, (i) {
      final e = entries[i];
      return MapLayerPOI(
        id: '3s-val-$i',
        name: e.name,
        position: LatLng(e.lat, e.lng),
        layerType: MapLayerType.threeSCenters,
        subtitle: '${e.city} • Local government office',
        city: e.city,
        facilityType: '3s_center',
        ownership: 'public',
        emergencyCapable: true,
      );
    });
  }

  static List<MapLayerPOI> _policeStations() {
    return [
      const MapLayerPOI(
        id: 'p-2',
        name: 'Police Station 4 (North)',
        position: LatLng(14.7514500, 121.0441970),
        layerType: MapLayerType.policeStations,
        subtitle: 'Zabarte Rd, Camarin',
      ),
    ];
  }

  static List<MapLayerPOI> _fireStations() {
    return [
      const MapLayerPOI(
        id: 'f-1',
        name: 'BFP Caloocan Fire Station',
        position: LatLng(14.6495, 120.9895),
        layerType: MapLayerType.fireStations,
        subtitle: 'Near City Hall, Grace Park',
      ),
      const MapLayerPOI(
        id: 'f-2',
        name: 'Deparo Fire Substation',
        position: LatLng(14.73727, 121.0324),
        layerType: MapLayerType.fireStations,
        subtitle: 'Deparo / Susano Rd',
      ),
    ];
  }

  static List<MapLayerPOI> _evacuationCenters() {
    return [
      const MapLayerPOI(
        id: 'e-1',
        name: 'Bagumbong Evacuation Center',
        position: LatLng(14.7507611, 121.0207885),
        layerType: MapLayerType.evacuationCenters,
        subtitle: 'Near Caloocan City Sports Complex',
      ),
    ];
  }

  static List<MapLayerPOI> _floodProneAreas() {
    return [
      const MapLayerPOI(
        id: 'flood-1',
        name: 'Deparo Flood-Prone Zone',
        position: LatLng(14.73727, 121.0324),
        layerType: MapLayerType.floodProneAreas,
        subtitle: 'Monitor during heavy rain',
        level: 'High',
      ),
      const MapLayerPOI(
        id: 'flood-2',
        name: 'Tala Lowland Area',
        position: LatLng(14.766534, 121.0657354),
        layerType: MapLayerType.floodProneAreas,
        level: 'Moderate',
      ),
    ];
  }

  static List<MapLayerPOI> _landslideProneAreas() {
    return [
      const MapLayerPOI(
        id: 'ls-1',
        name: 'Hillside Area - Bagumbong',
        position: LatLng(14.7507611, 121.0207885),
        layerType: MapLayerType.landslideProneAreas,
        level: 'Moderate',
      ),
    ];
  }

  static List<MapLayerPOI> _roadBlockages() {
    return [];
  }

  static List<MapLayerPOI> _trafficConditions() {
    return [
      const MapLayerPOI(
        id: 't-1',
        name: 'EDSA-Rizal Ave',
        position: LatLng(14.6575, 120.9842),
        layerType: MapLayerType.trafficConditions,
        level: 'Heavy',
        subtitle: 'Monumento',
      ),
    ];
  }

  static List<MapLayerPOI> _safeZones() {
    return [
      const MapLayerPOI(
        id: 'sz-1',
        name: 'City Hall Assembly Point',
        position: LatLng(14.6488536, 120.9906085),
        layerType: MapLayerType.safeZones,
        subtitle: 'Caloocan City Hall, 8th Ave',
      ),
      const MapLayerPOI(
        id: 'sz-2',
        name: 'Bagumbong Sports Complex',
        position: LatLng(14.7507611, 121.0207885),
        layerType: MapLayerType.safeZones,
      ),
    ];
  }

  static List<MapLayerPOI> _emergencyHotlines() {
    return [
      const MapLayerPOI(
        id: 'hotline-1',
        name: 'Emergency 911',
        position: LatLng(14.6488536, 120.9906085),
        layerType: MapLayerType.emergencyHotlines,
        subtitle: '911',
      ),
      const MapLayerPOI(
        id: 'hotline-2',
        name: 'DRRMO Caloocan',
        position: LatLng(14.6488536, 120.9906085),
        layerType: MapLayerType.emergencyHotlines,
        subtitle: 'Local emergency',
      ),
    ];
  }

  static List<MapLayerPOI> _bridgeConditions() {
    return [];
  }

  static List<MapLayerPOI> _riverLevels() {
    return [];
  }

  static List<MapLayerPOI> _supplyPoints() {
    return [
      const MapLayerPOI(
        id: 'sp-1',
        name: 'City Hall Relief Goods',
        position: LatLng(14.6488536, 120.9906085),
        layerType: MapLayerType.supplyPoints,
      ),
      const MapLayerPOI(
        id: 'sp-2',
        name: 'Bagumbong Distribution',
        position: LatLng(14.7507611, 121.0207885),
        layerType: MapLayerType.supplyPoints,
      ),
    ];
  }

  static List<MapLayerPOI> _weatherAlerts() {
    return [
      const MapLayerPOI(
        id: 'wx-1',
        name: 'Caloocan Weather',
        position: LatLng(14.6488536, 120.9906085),
        layerType: MapLayerType.weatherAlerts,
        subtitle: 'Check PAGASA',
      ),
    ];
  }

  static String layerLabel(MapLayerType type) {
    return switch (type) {
      MapLayerType.evacuationRoutes => 'Evacuation routes',
      MapLayerType.hospitals => 'Hospitals & clinics',
      MapLayerType.threeSCenters => '3S centers',
      MapLayerType.policeStations => 'Police stations',
      MapLayerType.fireStations => 'Fire stations',
      MapLayerType.evacuationCenters => 'Evacuation centers',
      MapLayerType.floodProneAreas => 'Flood-prone areas',
      MapLayerType.landslideProneAreas => 'Landslide-prone areas',
      MapLayerType.roadBlockages => 'Road blockages',
      MapLayerType.trafficConditions => 'Traffic conditions',
      MapLayerType.safeZones => 'Safe zones',
      MapLayerType.emergencyHotlines => 'Emergency hotlines',
      MapLayerType.incidentReports => 'Incident reports',
      MapLayerType.bridgeConditions => 'Bridge conditions',
      MapLayerType.riverLevels => 'River levels',
      MapLayerType.searchRescueLocations => 'SAR team locations',
      MapLayerType.supplyPoints => 'Supply distribution',
      MapLayerType.hazardZones => 'Hazard zones',
      MapLayerType.gpsVictims => 'GPS victim sharing',
      MapLayerType.weatherAlerts => 'Weather alerts',
    };
  }
}
