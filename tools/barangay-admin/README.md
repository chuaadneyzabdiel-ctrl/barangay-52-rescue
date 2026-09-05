# Local Barangay Admin

Manages **barangays** and **LGU accounts** in Firebase Realtime Database. It does **not** edit `CITIZEN/`, `RESPONDER/`, or `lguver` source. It never wipes `active_sos` or `users`.

Binds to [http://127.0.0.1:8788](http://127.0.0.1:8788) only.

Walkthrough for seed accounts, activating 53–56, isolation, and mutual aid: [EXPERIMENTAL.md](../../EXPERIMENTAL.md).

## Start

Double-click **Barangay Admin.lnk** in the repo root, or **start.bat** in this folder. Keep the console window open while you use it.

```powershell
python -u tools/barangay-admin/server.py
```

Needs Python 3.10+. No pip packages.

## Seed

Use **Seed missing 52–56 + brgy52/brgy56**. Missing rows are created. Existing neighbor lists only gain missing OSM neighbors. Map centers update to OSM centroids. `active_sos` / `users` are never wiped.

| Account | Password | Barangay |
|---------|----------|----------|
| `brgy52` | `Brgy52Admin1` | 52 (active) |
| `brgy56` | `Brgy56Admin1` | 56 (barangay row starts inactive) |

Barangays 53–56 are created inactive until you check **Active**. Create 53–55 LGU accounts here (example demo passwords are listed in [EXPERIMENTAL.md](../../EXPERIMENTAL.md)); do not put those passwords in the Flutter apps. Maps draw OSM outlines for 52–56; 52 stays the original green polygon.

## What it writes

- `/barangays/{id}` — `id`, `name`, `isActive`, `neighbors`, `mapCenter`
- `/lgu_accounts/{username}` — username, `barangayId`, `isActive`, `passwordHash`, `passwordSalt`

Passwords use the same hash as the LGU app: SHA-256 of `salt::password`. Plaintext is never stored.
