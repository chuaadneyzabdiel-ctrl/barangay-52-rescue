# Rescue App – Features to Add (System Spec)

## Implemented (this release)

1. **Rescuer online on dashboard open** – When a rescuer opens the app and lands on the rescue (dispatch) screen, the unit is registered from roster if needed and appears on LGU/citizen maps immediately.
2. **Audit log when user leaves dashboard** – On "Yes, go back" for Citizen, Rescuer, and LGU, a log entry is written to Firebase `audit_log` (timestamp, role, screen, unitId/sosId).
3. **Rescuer pick alternate route** – On the route preview screen, rescuer can tap "Route 2", "Route 3", etc. to select an alternate; Start Navigation uses the selected route.
4. **Firebase security rules** – `database.rules.json` defines rules per path (unit_locations, active_sos, sos_history, dispatch, hazard_zones, sos_chats, audit_log). Deploy via Firebase Console when ready.
5. **Offline / connectivity** – `ConnectivityBanner` shows "No connection. Updates will sync when back online." when the device is offline. Wraps the app in `MaterialApp.builder`.
6. **Two-way chat** – Citizen and rescuer can message each other for an SOS. Firebase path: `sos_chats/{sosId}/messages`. Chat panel opens via Message FAB (citizen tracking view, rescuer map navigation).
7. **Chat closes 2 hours after rescue complete** – When `completedAt` is set and 2 hours have passed, the chat is read-only ("This conversation is closed.").
8. **LGU sees all messages** – LGU dashboard: "View messages" (chat icon) on each SOS tile (active and history). Read-only panel.
9. **Notifications** – Citizen: local notification "Help is on the way!" when a responder is assigned. Rescuer: "New SOS request" when opening dispatch with pending SOS. Uses `flutter_local_notifications`.
10. **Live ETA (responder navigation)** – ETA uses remaining distance along the OSRM polyline, current GPS speed, **mock traffic** multipliers on route segments, and **stopped-time creep** so the value updates every second (not only on reroute). Not Google Traffic; for production traffic you’d add a paid Directions/traffic API.
11. **Traffic-colored route (mock)** – Route can render as blue / orange / red segments by simulated congestion. Toggle **Traffic on route** in the map layers sheet (default on). Solid blue if overlay is off.
12. **Responder marker direction** – Uses **GPS course** when speed is above threshold; otherwise bearing along the route polyline.
13. **Map type & details sheet** – Bottom sheet (layers icon) on citizen, dispatch, LGU, route preview, and responder navigation: basemap **Default, Light, Dark, Satellite (Esri), Terrain (OpenTopo)**; toggles for route traffic overlay and a placeholder “transit” switch. Uses raster tiles (OSM ecosystem), not the Google Maps SDK.
14. **Citizen cancel after dispatch** – Cancel SOS is available during tracking with **two-step confirmation** if a responder is already assigned.
15. **Responder dispatch actions** – While an SOS is active for the unit: **Navigation**, **Complete**, and **Cancel response** (with confirmations). Cancel uses `responderAbortSOS` (SOS → cancelled in history).
16. **LGU history timestamps** – History tiles show **created** and **ended** date/time (`intl`).
17. **Chat unread badge + local notification** – Chat FAB shows a count; new messages from the other party trigger a local notification (suppressed while chat sheet is open).
18. **Chat images** – Camera / gallery via `image_picker`, upload to **Firebase Storage** (`sos_chats/{sosId}/images/...`). Deploy **`storage.rules`** and enable Storage in Firebase Console.

## Mobile-first (cellphone)

- All new UI uses bottom sheets (`DraggableScrollableSheet`, initialChildSize 0.6) for chat so it fits on small screens.
- Route preview uses horizontal `SingleChildScrollView` for route chips.
- Connectivity banner is a slim top bar so it doesn’t cover content.
- No fixed widths that break on narrow screens.

## Future (when ready)

- **Accounts per dashboard** – Login for Rescuer and LGU; allowlist so only approved users can use each dashboard.
- **Verification profiles** – Phone, address, ID picture per dashboard; rescue: driver’s license, driver name, companion name + image.
