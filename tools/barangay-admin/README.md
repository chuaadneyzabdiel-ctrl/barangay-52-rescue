# Local Barangay Admin

Manages **barangays** and **LGU accounts** in Firebase Realtime Database. It does **not** edit `CITIZEN/`, `RESPONDER/`, or `lguver` source. It never wipes `active_sos` or `users`.

Binds to [http://127.0.0.1:8788](http://127.0.0.1:8788) only.

## Start

Double-click **Barangay Admin.lnk** in the repo root, or **start.bat** in this folder. Keep the console window open while you use it.

```powershell
python -u tools/barangay-admin/server.py
```

Needs Python 3.10+. No pip packages.

## Seed

Use **Seed missing 52–55 + brgy52**. Existing rows are left alone.

| Account | Password | Barangay |
|---------|----------|----------|
| `brgy52` | `Brgy52Admin1` | 52 (active) |

Barangays 53–55 are created inactive until you check **Active**.

## What it writes

- `/barangays/{id}` — `id`, `name`, `isActive`, `neighbors`, `mapCenter`
- `/lgu_accounts/{username}` — username, `barangayId`, `isActive`, `passwordHash`, `passwordSalt`

Passwords use the same hash as the LGU app: SHA-256 of `salt::password`. Plaintext is never stored.
