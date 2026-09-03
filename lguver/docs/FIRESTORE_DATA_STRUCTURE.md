# Firestore Data Structure

This document defines the Firestore collections and sample documents for the emergency response system.

## 1) `users/{userId}`

Fields:
- `role`: `'citizen' | 'responder' | 'lgu'`
- `name`: non-empty string, max 100 chars
- `email`: string (format and uniqueness handled by Firebase Auth)
- `createdAt`: timestamp
- `updatedAt`: timestamp

Sample:

```json
{
  "role": "citizen",
  "name": "Juan Dela Cruz",
  "email": "juan@example.com",
  "createdAt": "serverTimestamp",
  "updatedAt": "serverTimestamp"
}
```

## 2) `guests/{deviceId}`

Fields:
- `deviceId`: Firebase Installation ID
- `sosCount`: integer 0..3 (resets daily)
- `lastSosAt`: timestamp
- `strikes`: integer 0..3
- `isBanned`: boolean
- `bannedAt`: timestamp or null
- `banReason`: string or null
- `guestName`: optional string, non-empty if present, max 100 chars

Sample:

```json
{
  "deviceId": "fid_abc123",
  "sosCount": 1,
  "lastSosAt": "serverTimestamp",
  "strikes": 0,
  "isBanned": false,
  "bannedAt": null,
  "banReason": null,
  "guestName": "Anonymous Caller"
}
```

## 3) `sos/{sosId}`

Fields:
- `citizenId`: userId or null for guest
- `deviceId`: always present
- `guestName`: optional, guest only
- `isGuest`: boolean
- `location`: `{ lat, lng }` with PH bounds (`lat: 4.0..21.0`, `lng: 116.0..127.0`)
- `status`: `'pending' | 'accepted' | 'completed' | 'cancelled'`
- `cancelReason`: required min 10 chars on cancel
- `cancelledAfterDispatch`: boolean
- `assignedResponderId`: responder userId or null
- `createdAt`: timestamp
- `resolvedAt`: timestamp or null

Sample:

```json
{
  "citizenId": null,
  "deviceId": "fid_abc123",
  "guestName": "Guest A",
  "isGuest": true,
  "location": { "lat": 14.699, "lng": 121.02 },
  "status": "pending",
  "cancelReason": null,
  "cancelledAfterDispatch": false,
  "assignedResponderId": null,
  "createdAt": "serverTimestamp",
  "resolvedAt": null
}
```

## 4) `responders/{userId}`

Fields:
- `unitName`: string, non-empty, max 50 chars, unique (checked in helper function)
- `isOnline`: boolean
- `currentLocation`: `{ lat, lng }` or null
- `lastHeartbeatAt`: timestamp or null
- `activeSosId`: sosId or null
- `approvedByLgu`: boolean (default false)

Sample:

```json
{
  "unitName": "AMBULANCE-01",
  "isOnline": false,
  "currentLocation": null,
  "lastHeartbeatAt": null,
  "activeSosId": null,
  "approvedByLgu": false
}
```

## 5) `hazards/{hazardId}`

Fields:
- `type`: `'flood' | 'fire' | 'road_obstruction' | 'other'`
- `location`: `{ lat, lng }` (same PH bounds)
- `description`: non-empty string, min 10 chars
- `isActive`: boolean
- `createdBy`: LGU userId
- `createdAt`: timestamp
- `resolvedAt`: timestamp or null

Sample:

```json
{
  "type": "flood",
  "location": { "lat": 14.73, "lng": 121.04 },
  "description": "Floodwater is knee-deep near the market area.",
  "isActive": true,
  "createdBy": "lgu_123",
  "createdAt": "serverTimestamp",
  "resolvedAt": null
}
```

## 6) `auditLogs/{logId}`

Fields:
- `action`: string
- `performedBy`: userId or deviceId
- `targetId`: sosId or userId or deviceId
- `details`: map
- `timestamp`: timestamp

Sample:

```json
{
  "action": "APPROVE_RESPONDER",
  "performedBy": "lgu_123",
  "targetId": "responder_456",
  "details": { "approvedByLgu": true },
  "timestamp": "serverTimestamp"
}
```

## Suggested Firestore indexes

- `sos`: `citizenId ASC, status ASC, createdAt DESC`
- `sos`: `deviceId ASC, status ASC, createdAt DESC`
- `responders`: `unitName ASC`
- `responders`: `isOnline ASC, lastHeartbeatAt ASC`
