# Barangay 52 Rescue — Stable Snapshot (`v1.0.0`)

Caloocan City **Integrated Rescue Operation Dispatch & Dynamic Relocation System** for Barangay 52.

This repository is the **stable three-app snapshot**. Tag **`v1.0.0`** is this tree.

Three Flutter clients share one Firebase project (`rescue-app-c79cf`) and **Firebase Realtime Database**:

| Folder | App | Role |
|--------|-----|------|
| `CITIZEN/citizen27` | Citizen (Android) | SOS, live tracking, registered or guest access |
| `RESPONDER/responderv3` | Responder (Android) | Unit login, dispatch, GPS, navigation |
| `lguver` | LGU command center (Windows / web) | Live map, hazards, accounts, relocation |

## Clone and run

Requires [Flutter](https://flutter.dev) (SDK `^3.11.0`) and a configured Android/Windows toolchain.

```bash
git clone https://github.com/<your-account>/barangay-52-rescue.git
cd barangay-52-rescue
```

Citizen:

```bash
cd CITIZEN/citizen27
flutter pub get
flutter run
```

Responder:

```bash
cd RESPONDER/responderv3
flutter pub get
flutter run
```

LGU:

```bash
cd lguver
flutter pub get
flutter run -d windows
# or: flutter run -d chrome
```

## How the apps connect

Citizen SOS → `active_sos` → responder accepts → `dispatch` + `unit_locations` GPS → citizen tracks the unit. Completed/cancelled requests move to `sos_history`. Chat lives under `sos_chats` and `lgu_responder_chats`.

Routing uses public **OSRM** (road-following) plus **A\*** for hazard-aware paths. Maps use OpenStreetMap tiles via `flutter_map`.

## Security note

This is a **capstone snapshot**, not a production deployment.

Firebase **client** config (`google-services.json`, web API keys) is included so the apps can build. The Realtime Database rules in this tree are open (`.read` / `.write` true). **Lock those rules before any real deployment.** Do not point a public demo at a live database with open rules.

## Docs

Each app has a `docs/` folder (data structure notes, map tiles, feature list). Per-app `README.md` files still describe an older single-app role-picker layout; this root README is the source of truth for `v1.0.0`.
