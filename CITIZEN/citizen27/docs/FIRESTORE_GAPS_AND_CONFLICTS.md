# Firestore Gaps and Conflicts

This file captures practical constraints and decisions related to the Firestore + Cloud Functions design.

## 1) Guest `deviceId` trust boundary

- Firestore rules cannot cryptographically verify Firebase Installation ID for unauthenticated users.
- To prevent spoofing and bypassing bans/cooldowns/caps, guest SOS create/cancel is routed through Cloud Functions.
- Enable Firebase App Check for Functions and Firestore to reduce abuse.

## 2) Rule-level vs function-level enforcement

- Firestore rules enforce role and field constraints for direct client writes.
- Business logic requiring cross-document checks and counters (cooldown, daily cap, strike escalation, auto-ban) is enforced in Cloud Functions.

## 3) Unit name uniqueness

- Firestore rules cannot guarantee global uniqueness by themselves.
- `createResponder` checks `responders.unitName` via query before create.
- For stricter guarantees, add a lock collection (e.g. `unitNames/{normalized}`) in a transaction.

## 4) Guest reset policy

- Daily guest SOS reset is implemented on every guest send attempt by comparing `lastSosAt` day with current day (UTC).
- If you require local midnight (e.g. Asia/Manila), adjust day-boundary logic in helpers.

## 5) Realtime Database coexistence

- Existing app currently uses Realtime Database for core flows.
- This Firestore package is additive and does not yet migrate Flutter service calls.
- A separate migration pass is required to switch app reads/writes from RTDB paths to Firestore collections.

## 6) LGU cannot directly modify SOS

- Rules intentionally block LGU direct SOS writes as required.
- Any future forced intervention (e.g. admin close stale SOS) should be done through a privileged Cloud Function with audit logging.
