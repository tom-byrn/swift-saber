# AirPods case motion helpers

These two command-line helpers let Swift Saber read an AirPod's motion sensors while the
earbuds sit inside the **closed charging case**, so the case itself becomes the saber hilt.

They come unchanged from [AirPointer](https://github.com/musubipapi/airpointer) by Andy Gao
(MIT License, see `LICENSE`), at commit `a73cc798e71a2e4c568f5a2ec8a351a58cd8e311`.

| File | Built as | Job |
| --- | --- | --- |
| `ClosedCaseRestore.swift` | `Contents/Resources/ClosedCaseRestore.bin` | Makes sure the AirPods' ordinary Bluetooth link is up. |
| `ClosedCaseMotion.m` | `Contents/Resources/ClosedCaseMotion.bin` | Reconnects once, opens the AACP channel, starts the accelerometer and gyro, keeps the closed case awake and streams motion rows on stdout. |

`ClosedCaseMotion.m` documents its exit codes at the top; Swift Saber puts them in plain
words in `Sources/SaberCore/CaseMotion.swift`. The app talks to it through files in the
session folder: it renews `app-lease.txt` every second, writes `closed_confirmed` or `stop`
to `recording/phase.txt`, and reads `recording/status.json`.

`Scripts/build-app.sh` compiles both and signs them into the app bundle.

These use private Bluetooth APIs, were tested by their author on AirPods Pro 3 with macOS 26,
and recognise AirPods Pro 2. See AirPointer's README for what a session changes on the AirPods.
