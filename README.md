# Fire TV Sideload

A tiny Windows GUI that installs (sideloads) Android `.apk` files onto an
Amazon Fire TV Stick over your Wi-Fi network using ADB. No build step, no
installer, no .NET SDK — it runs on the PowerShell that already ships with
Windows 10/11.

## Run it

Double-click **`Sideload.bat`**.

On first launch it downloads Google's official `platform-tools` (adb) into
`tools\platform-tools\` automatically — that's the only network dependency and
it happens once.

## One-time setup on the Fire TV Stick

1. **Settings → My Fire TV → About → click "Fire TV Stick 4K Max" 7 times** to
   unlock Developer Options.
2. **Settings → My Fire TV → Developer Options**:
   - Turn **ON** "ADB Debugging".
   - (Optional) Turn **ON** "Apps from Unknown Sources" so sideloaded apps run.
3. Find the Stick's IP address: **Settings → Network → (your Wi-Fi) → the
   `192.168.x.x` address**.

## Using the app

1. Type the Stick's IP into the **Stick IP** box (port is always `5555`).
2. Click **Connect**.
3. **Look at the TV** — the first time, it shows an "Allow USB debugging?"
   prompt with an RSA fingerprint. Tick **"Always allow from this computer"**
   and choose **OK**.
4. Click **Devices** to confirm the Stick shows as `device` (not
   `unauthorized` / `offline`).
5. Install an app either by:
   - Clicking **Install APK...** and picking one or more `.apk` files, or
   - **Dragging** `.apk` files anywhere onto the window.

`-r` (reinstall keeping data) and `-d` (allow version downgrade) are passed to
the device's package manager, so re-pushing an updated build over an existing
app just works.

## How installs actually happen

`adb install` over Wi-Fi frequently hangs forever on Fire TV, so this app does
what the reliable tools do instead — three steps on the device:

1. `adb push yourapp.apk /data/local/tmp/`
2. `adb shell pm install -r -d /data/local/tmp/yourapp.apk`
3. `adb shell rm -f` the temp copy

Every adb command also has a **timeout watchdog** (30s, or 180s for the install
step). If adb hangs, the app kills it, says so in the log, and re-enables the
buttons instead of sitting there greyed out forever.

On startup the app runs `adb kill-server` first. Closing the app does **not**
stop the background adb daemon, so a wedged daemon from a previous session can
otherwise poison every command in the next one.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Buttons greyed out and nothing happening | Fixed automatically now - the watchdog releases them within 30s. If you are on the older build, close and reopen the app. |
| `unauthorized` in the log | Accept the RSA prompt on the TV screen. If none appears, toggle ADB Debugging off/on, or **Disconnect** then **Connect** again. |
| `failed to connect` / `NOT connected` | Wrong IP, ADB Debugging off, or the Stick is asleep. Wake it and re-check the IP (DHCP hands out changes). |
| `offline` in `adb devices` | The Stick's adbd is wedged, usually from an aborted install. **Unplug the Stick's power for 10s** - that is the reliable reset - then connect again. |
| Install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | An existing app was signed with a different key; uninstall it on the Stick first. |
| Install fails with `INSTALL_FAILED_OLDER_SDK` etc. | The APK genuinely does not support Fire OS; nothing to do with sideloading. |


## Files

- `Sideload.bat` — launcher (bypasses execution policy, hides the console).
- `Sideload.ps1` — the WinForms app.
- `tools\platform-tools\` — auto-downloaded adb (safe to delete; it re-downloads).
- `last-ip.txt` — remembers your last IP (created on first Connect).
