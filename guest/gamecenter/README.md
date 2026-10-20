# 游戏中心 / Game Center (guest app)

The app that sits in screen 0, cell (0,0) of the Kolibri in-guest desktop.
The launcher fork points at these fixed identifiers — don't rename them:

| | |
|---|---|
| applicationId | `dev.kolibri.gamecenter` |
| launcher activity | `dev.kolibri.gamecenter.MainActivity` |
| minSdk / target / compile | 30 / 36 / 36 |

Kotlin + Jetpack Compose, single Gradle module (the root project is the app), dark
landscape-first UI (`sensorLandscape`, built for the 1600×900 @ 320 dpi guest).

## What it does (all offline)

- **我的游戏 / My games** — launchable apps the system classifies as games
  (`ApplicationInfo.CATEGORY_GAME` or the legacy `FLAG_IS_GAME`), plus anything the user pins.
  Tap to launch; long-press for launch / add-or-remove / app info / uninstall.
  Overrides are two string sets in SharedPreferences (`pinned`, `hidden`), so a declared game
  can also be removed.
- **全部应用 / All apps** — every launchable app, with a star on those in My games; long-press
  to add or remove.
- **安装 APK / Install APK** — system document picker (`ACTION_OPEN_DOCUMENT`,
  `application/vnd.android.package-archive`), then the APK is streamed into a
  `PackageInstaller` session. The system confirmation dialog comes back via a non-exported
  broadcast (`STATUS_PENDING_USER_ACTION`). If "install unknown apps" isn't granted yet, the app
  opens that settings page first. Single APKs only — no `.apks`/`.xapk` splits.
- **性能 / Performance** — model, brand/manufacturer, Android version, ABIs, cores, RAM; current
  refresh rate, resolution and supported display modes (live via `DisplayListener`); a button
  that sets `preferredDisplayModeId` on the Game Center window to the highest-refresh mode at the
  current resolution (demo only — it affects this window, not other apps).
- **Empty state** with a four-step tutorial when no games are found.

Privacy: no `INTERNET` permission, no analytics, no network code. Package visibility uses a
`<queries>` launcher-intent filter instead of `QUERY_ALL_PACKAGES`. Other permissions:
`REQUEST_INSTALL_PACKAGES`, `REQUEST_DELETE_PACKAGES`.

UI strings are Chinese by default with an English `values-en` translation.

## Build

```bash
./build.sh            # release (R8-minified, signed with the local debug key) → out/GameCenter.apk
./build.sh debug      # debug build → out/GameCenter.apk
./build.sh install    # release build, then adb install -r
```

`build.sh` uses `$ANDROID_HOME` (default `~/Library/Android/sdk`, needs platform 36), writes
`local.properties`, and picks JDK 21 or 17 (Homebrew `openjdk@21`/`@17`, `java_home`, or Android
Studio's JBR) unless `JAVA_HOME` is set — AGP doesn't support the newest JDKs. Toolchain:
Gradle 9.7.1 wrapper, AGP 9.4.1 (built-in Kotlin), Kotlin Compose plugin 2.4.21,
Compose BOM 2026.09.00.

The release build is signed with the debug key so it's installable as-is; sign with a real key
before distributing outside the Kolibri image.

## Layout

```
build.gradle.kts / settings.gradle.kts   single-module Android app
src/main/AndroidManifest.xml
src/main/java/dev/kolibri/gamecenter/
  MainActivity.kt      intents (launch/info/uninstall/install), install-status receiver, display-mode request
  GameRepository.kt    PackageManager scan + game classification + user overrides
  ApkInstaller.kt      PackageInstaller session
  DeviceInfo.kt        Build/Display/memory readouts
  ui/Theme.kt, ui/GameCenterApp.kt   Compose UI
src/main/res/          adaptive icon (original gamepad glyph), strings (zh default, en), theme
```
