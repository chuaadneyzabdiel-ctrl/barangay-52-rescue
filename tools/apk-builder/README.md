# Local APK Builder

Builds a **release APK** from Citizen or Responder without editing those project folders (or GitHub `v1.0.0`). The selected app is copied to a temp directory, patched there, built, then the APK is saved where you choose.

## Start

Double-click **APK Builder.lnk** in the repo root, or **start.bat** in this folder. That starts the server and opens [http://127.0.0.1:8787](http://127.0.0.1:8787). Keep the black console window open while you use it.

From the command line:

```powershell
python -u tools/apk-builder/server.py
```

Needs Python 3.10+ and Flutter on PATH (or `FLUTTER_ROOT`).

## Form order

1. **Source app** — Citizen, Responder, or browse to a Flutter folder
2. **Output location** — folder + filename for the `.apk`
3. **Android application ID** — change this if you want both apps on one phone
4. **App name** — optional launcher label
5. **Icon** — optional PNG
6. **Build** — live log, then download / saved path

If the output file already exists, you can overwrite or rename.

This tool does **not** commit, push, or retag `v1.0.0`.
