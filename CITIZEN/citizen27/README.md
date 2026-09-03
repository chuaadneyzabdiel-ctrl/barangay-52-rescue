# Caloocan City Integrated Rescue Operation Dispatch & Dynamic Relocation System

A dual-platform Flutter application (Android + Web) for emergency rescue dispatch in Caloocan City with **real-time mutual tracking** between Citizens and Responders.

## Architecture

```
lib/
├── main.dart                          # Entry point, Firebase init, Provider setup
├── models/
│   └── rescue_models.dart             # HazardZone, RescueUnit, SOSRequest, StandbyPoint, RouteNode
│                                       (with toJson/fromJson for Firebase serialization)
├── services/
│   ├── a_star_routing_service.dart     # A* pathfinding with hazard zone avoidance
│   ├── osrm_routing_service.dart       # OSRM public API for road-following routes (no API key)
│   ├── dynamic_relocation_service.dart # Coverage-gap relocation engine
│   ├── location_service.dart           # GPS stream wrapper (Geolocator)
│   └── firebase_sync_service.dart      # Firebase Realtime Database sync layer
├── providers/
│   └── rescue_provider.dart            # Central state — Firebase + OSRM + A* integration
├── screens/
│   ├── role_selection_screen.dart       # Role picker (Citizen / Responder / LGU)
│   ├── map_navigation_screen.dart      # FlutterMap live navigation with dual routes
│   ├── citizen/
│   │   └── sos_screen.dart             # SOS button → waiting → live responder tracking
│   ├── responder/
│   │   └── dispatch_screen.dart        # Firebase SOS alerts, GPS upload, accept & navigate
│   └── dashboard/
│       └── lgu_dashboard_screen.dart   # Command Center: live map, hazard tagging, relocation
└── utils/
    └── geo_utils.dart                  # Haversine, bearing, grid neighbor helpers
```

## Setup

### 1. Firebase Setup (one-time, ~5 minutes)

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a project (e.g., "Caloocan Rescue")
3. Go to **Build** → **Realtime Database** → **Create Database** → Start in **test mode**
4. Add an **Android app**:
   - Package name: `com.caloocan.rescue.rescue_app`
   - Download `google-services.json` → place in `android/app/`
5. Add a **Web app**:
   - Copy the Firebase config and update `web/index.html` if needed

No billing or credit card is required.

### 2. Install & Run

```bash
flutter pub get
flutter run               # Android
flutter run -d chrome     # Web (LGU Dashboard)
```

## Key Components

### Real-Time Firebase Sync
- `/unit_locations/{unitId}` — Responder GPS updated every 3 seconds
- `/active_sos/{sosId}` — Citizen SOS with live location updates
- `/hazard_zones/{zoneId}` — LGU-tagged hazard zones synced to all devices
- `/dispatch/{sosId}` — Dispatch status (pending → accepted → en_route → on_scene)

### A* Routing Service
- Heuristic: Haversine straight-line distance (admissible & consistent)
- 8-directional grid expansion at configurable resolution (default 150m)
- Hard-blocks nodes inside hazard zone polygons
- Soft-penalizes edges near hazard boundaries proportional to severity weight

### OSRM Road Routing (Free, No API Key)
- Calls the public OSRM API for accurate road-following routes
- Returns decoded GeoJSON geometry, ETA in minutes, distance in km
- Displayed as solid blue polyline alongside the A* dashed orange route

### Dynamic Relocation Engine
- 8 candidate standby points across North and South Caloocan
- Scoring by: coverage gap distance, active incident density, district balance
- Greedy assignment of idle units to highest-priority gaps

## Live Tracking Flow

```
Citizen taps SOS → Firebase /active_sos/ ← Responder sees alert
                                          → Responder taps Accept
                                          → Firebase /dispatch/ updated
Citizen sees responder ← Firebase /unit_locations/ ← Responder GPS streams
approaching on map                                     every 3 seconds
```

## Platforms

| Role | Platform | Features |
|------|----------|----------|
| Citizen | Android | SOS button, live responder tracking, ETA |
| Responder | Android | Real-time SOS alerts, accept & navigate, GPS streaming |
| LGU Admin | Web | Live map of all assets, hazard zone tagging, relocation suggestions |

## API Keys Required

**None.** The app uses:
- **OpenStreetMap** tiles (free, no key)
- **OSRM** routing API (free, no key)
- **Geolocator** for GPS (hardware, no key)
- **Firebase** Realtime Database (free tier, no billing)
