# Kolibri Launcher (guest home app)

Kolibri Launcher is the Android home app shipped in the Kolibri guest. It is a
small, reproducible fork of [Lawnchair](https://github.com/LawnchairLauncher/lawnchair).
The fork only changes defaults, so that a fresh guest opens on a game-focused home
screen: a 4×5 grid with a Tutorial shortcut on the first page,
and Settings, Gallery, Files and Browser in the dock.

The source tree is not vendored. `build.sh` clones a pinned Lawnchair commit into
`src/` and applies the changes from this folder on top of it.

| Path | What it is |
|---|---|
| `build.sh` | Clone or reset `src/`, apply `patches/`, copy `overlay/`, build `out/KolibriLauncher.apk` |
| `install.sh <serial>` | Install the APK, make it home, wipe its data so the default layout loads |
| `patches/*.patch` | Changes to existing Lawnchair files (`git apply` against the pinned commit) |
| `overlay/` | New files copied into the tree as they are |
| `src/`, `out/`, `.jdk/`, `build.log` | Generated, gitignored |

## Build

```bash
guest/launcher/build.sh
```

- **Upstream:** Lawnchair tag `v15.0.0-beta3.0`, commit `505dbc40e6154c05158b5d0271c45f6a885a411b`
  (Launcher3 15 base). It compiles against API 36 and runs on the API 36 guest as a
  third-party home app. Lawnchair's Quickstep recents integration only works when it is
  installed as a privileged system app, so recents stay with the system.
- **Toolchain:** Gradle 9.3 (wrapper) and AGP 9.0 need JDK 17 to 25 to run. The script
  uses `$JAVA_HOME` or `/usr/libexec/java_home -v 21|17|25`. If none of those work (for
  example only JDK 26 is installed), it downloads Eclipse Temurin 21 into `.jdk/`.
- **SDK:** `$ANDROID_HOME` (default `~/Library/Android/sdk`). AGP downloads build-tools
  36.1.0 and platform 36.1 itself if they are missing; the SDK licenses must already be
  accepted.
- **Variant:** `lawnWithQuickstepKolibriRelease`. The release build is minified and signed
  with the debug key, because no `keystore.properties` is present.
- **Iterating:** `SKIP_RESET=1 build.sh` rebuilds `src/` as it is. After you edit tracked
  files, regenerate the matching patch with `git -C src diff <files> > patches/NNNN-….patch`.

## Install

```bash
guest/launcher/install.sh emulator-5554
```

The script installs the APK and wipes the launcher's data (`pm clear`), so the next start
loads the default layout. It then makes `dev.kolibri.launcher/app.lawnchair.LawnchairLauncher`
the home app with `cmd package set-home-activity`, falling back to the HOME role.

The stock launcher (`com.google.android.apps.nexuslauncher` / Launcher3) is disabled with
`pm disable-user` only if home does not switch any other way, or if you pass
`--disable-stock`. On Pixel-style images that package also provides Recents, so it is
kept enabled by default.

## What changed from Lawnchair

1. **Identity** (`patches/0001`): adds a `kolibri` product flavor (now the default) with
   `applicationId dev.kolibri.launcher`, so it installs next to stock Lawnchair and the
   system launcher. The app label is "Kolibri Launcher". Java/Kotlin packages and class
   names are unchanged.
2. **Grid and home defaults** (`patches/0002`):
   - The `4_by_5` grid option (4 columns, 5 rows, 4 hotseat icons) now uses
     `@xml/default_workspace_4x5_kolibri`.
   - It is enabled for `tablet` as well as phone, so it stays the default if the guest
     display ever reaches 600dp smallest width.
   - It gains a "Kolibri Landscape" display option sized for the 1600×900 @ 320dpi guest
     (800×450dp).
   - Lawnchair already defaults to 4×5×4 in its grid prefs, and `4_by_5` is the first grid
     that matches, so this grid is picked on first start.
   - The At-a-Glance smartspace row (which takes the first row of page 0) and the dock
     search bar now default to off. The hotseat bottom spacing factor is 0.5 and icons are
     44dp, so that 5 rows with labels fit in 450dp of height.
   - `DeviceProfile` no longer transposes the layout in landscape on a phone-sized display.
     The guest is landscape with a 450dp smallest width, so stock Launcher3 would put the
     hotseat in a vertical bar on the right; it now stays a dock along the bottom.
3. **Default layout** (`overlay/lawnchair/res/xml/default_workspace_4x5_kolibri.xml`):
   - **Page 0, cell (0,0):** "Tutorial", which opens
     `https://github.com/kolibri/kolibri#readme` in the default browser. The URL is a
     placeholder, set in `overlay/lawnchair/res/values/kolibri_strings.xml`.
   - **Hotseat 0 to 3:**
     - **Settings:** `android.settings.SETTINGS`, falling back to `com.android.settings/.Settings`.
     - **Gallery:** the `APP_GALLERY` category, falling back to `images/*`.
     - **Files:** DocumentsUI (AOSP `com.android.documentsui` or the Google-branded
       `com.google.android.documentsui` package).
     - **Browser:** the `APP_BROWSER` category.
4. **Tutorial entry** (`patches/0003`, plus `TutorialActivity.kt` and its icon in `overlay/`):
   - Launcher3 15 dropped web shortcuts with a custom title and icon, i.e. legacy
     `ITEM_TYPE_SHORTCUT` items: the loader, inflater and model all ignore them now.
   - Instead, the launcher package contains `app.lawnchair.kolibri.TutorialActivity`, a
     tiny no-UI launcher activity labelled "Tutorial" that opens the URL. The layout places
     it like any app icon.
   - It is listed in Lawnchair's `filtered_components` (in `patches/0002`), so it appears
     only on the home screen, not in the app drawer.

The layout copies the arrangement of the stock home screen in other Android game
emulators (grid size and the position of each entry). It uses no third-party assets or
names: the tutorial icon (`ic_kolibri_tutorial*.xml`) is original artwork.

## License

Lawnchair is licensed under the GNU General Public License v3.0 (`src/LICENSE.txt`, after
cloning). It includes AOSP Launcher3 code under the Apache License 2.0, and those files
keep their original headers.

Kolibri Launcher is a modified version of Lawnchair and is distributed under the
**GPL-3.0** as well. That covers the patches, the overlay files and any APK built from
them. Anyone who distributes `KolibriLauncher.apk`, including bundled in a Kolibri guest
image, must also offer the corresponding source: this folder plus the pinned upstream
commit. New files carry a GPL-3.0-or-later notice, and upstream copyright and license
notices are left in place.
