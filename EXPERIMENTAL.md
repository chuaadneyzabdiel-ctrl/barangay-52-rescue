# experimental-adney — multi-barangay notes

This branch is **not** the stable `v1.0.0` snapshot. Do not retag `v1.0.0`. The root [README.md](README.md) still describes that snapshot.

`experimental-adney` adds barangay ownership, a localhost admin, LGU login scoped to one barangay, and neighbor mutual aid. Barangay 52 SOS extras from `experimental-nem` stay as they are (pin / report-for-someone-else, optional callback phone, Barangay 52 outline, chat number, optional scene photo, nearby hospital, extra Send SOS confirm). New work only adds `barangayId` and mutual-aid fields.

Work on this branch only. Do not commit to `experimental-nem`.

## Apps

Same three clients as `v1.0.0`:

| Folder | App |
|--------|-----|
| `CITIZEN/citizen27` | Citizen |
| `RESPONDER/responderv3` | Responder |
| `lguver` | LGU command center |

Firebase project: `rescue-app-c79cf`  
Realtime Database: `https://rescue-app-c79cf-default-rtdb.asia-southeast1.firebasedatabase.app`

Legacy rows with no `barangayId` are treated as **`"52"`**, so the current Barangay 52 demo keeps working.

## Barangay admin (localhost)

Admin config lives in Firebase, not in the Flutter trees.

1. Double-click **Barangay Admin.lnk** in the repo root, or run `tools/barangay-admin/start.bat`.
2. Or: `python -u tools/barangay-admin/server.py`
3. Open [http://127.0.0.1:8788](http://127.0.0.1:8788). It binds to localhost only.

Full tool notes: [tools/barangay-admin/README.md](tools/barangay-admin/README.md).

### Seed Barangay 52

In the admin UI, use **Seed missing 52–55 + brgy52**. Existing rows are left alone. It never wipes `active_sos` or `users`.

| Account | Password | Barangay |
|---------|----------|----------|
| `brgy52` | `Brgy52Admin1` | 52 |

The LGU app also seeds this account once if it is missing. Hashing matches Flutter: SHA-256 of `salt::password`.

### Activate barangays 53–55

1. Seed if those barangay rows do not exist yet (they start with **Active** unchecked).
2. For `53`, `54`, and `55`, check **Active** and save.
3. Create LGU accounts in the admin (do not hardcode them in Flutter). Demo passwords used for isolation tests:

| Account | Password | Barangay |
|---------|----------|----------|
| `brgy53` | `Brgy53Admin1` | 53 |
| `brgy54` | `Brgy54Admin1` | 54 |
| `brgy55` | `Brgy55Admin1` | 55 |

Citizen signup then lists any barangay with `isActive: true`. Offline fallback is **52 only**.

## Test isolation

1. Register a citizen on Barangay 52 and send SOS.
2. Sign in LGU as `brgy52` / `Brgy52Admin1`. Title should read **Barangay 52 Command Center**. The SOS and Barangay 52 units appear.
3. Sign out, sign in as `brgy53` / `Brgy53Admin1`. Title should read **Barangay 53 Command Center**. The Barangay 52 SOS must **not** appear (no `barangayId` still counts as 52).
4. Register or send SOS as a Barangay 53 citizen. Only `brgy53` should see that request. `brgy52` should not.

Roster extras for this test: `AMBULANCE-53`, `FIRE-54`, `TANOD-55`.

## Test mutual aid

Do **not** use **ASSIST UNIT** (that is LGU → assigned responder chat). Use **Request neighbor assistance** on the SOS sheet.

1. LGU 52 opens a home SOS → **Request neighbor assistance** → pick neighbor `53`, unit types, message → send.
2. LGU 53 sees the inbound card → **Accept**. The SOS gets `assistingBarangayIds` and shows **Assisting barangay 53**.
3. A Barangay 53 unit of a requested type sees that SOS on dispatch with an assisting badge and can accept it.
4. LGU 52 sheet stays **Home barangay 52**. Events land in `audit_log` (`MUTUAL_AID_REQUESTED`, `MUTUAL_AID_ACCEPTED` / `DECLINED`, `MUTUAL_AID_UNIT_ACCEPT`).

Neighbors come from `barangays/{id}/neighbors`.

## RTDB paths

| Path | Role |
|------|------|
| `users/{uid}` | Citizen profile, including `barangayId` |
| `barangays/{id}` | Catalog (`isActive`, `neighbors`, `mapCenter`) |
| `lgu_accounts/{username}` | LGU login (`barangayId`, hashed password) |
| `active_sos/{id}` | SOS with `barangayId`, `assistingBarangayIds`, `assistingUnitTypes` |
| `sos_history/{id}` | Closed SOS, same ownership fields |
| `unit_locations/{unitId}` | Live unit GPS, including `barangayId` |
| `mutual_aid_requests/{id}` | Neighbor request/accept/decline |
| `audit_log` | Login, mutual aid, and unit-accept events |

## LGU login

LGU has no Firebase Auth. Login is RTDB `lgu_accounts` plus the same salt+SHA-256 check as responder `unit_accounts`. Session keys: `lgu_username`, `lgu_assigned_barangay_id`. Bootstrap without a stored session returns to login.
