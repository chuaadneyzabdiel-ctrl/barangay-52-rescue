# Responder GPS joystick (debug)

Debug-only tool to spoof an active responder’s GPS for waypoint / navigation testing.

## Open

Double-click **`start.bat`** in this folder.

Or from a terminal:

```bat
tools\responder-gps-joystick\start.bat
```

## Notes

- Only works in **debug** Flutter runs (`kDebugMode`).
- Spoof stays **OFF** until you turn it on in the UI.
- Does not change release / production GPS behavior.
- Launches `RESPONDER/responderv3` in Chrome with `--dart-define=OPEN_GPS_JOYSTICK=true`.
