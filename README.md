# Phigros Library

Flutter app and local tools for building a current Phigros resource library from the latest available APK.

## Builds

GitHub Actions builds Android and Linux artifacts on every push, pull request,
and manual dispatch:

- Android debug APK: `phi-res-extract-android-debug`
- Linux debug bundle: `phi-res-extract-linux-debug`

## Android usage

Install the APK from the `phi-res-extract-android-debug` artifact. The Android
package does not bundle TapTap, the Phigros APK, or extracted resources. The
`APK Metadata` workflow only resolves the latest official APK download address
and publishes a small `taptap-apk.json` file under the `apk-latest` release.
The JSON contains only the URL, version, size, MD5, and update date.

On Android, tap `下载 APK`. The app fetches that JSON, downloads the APK at
runtime into its private data directory, and shows download progress. APK
resource extraction is intentionally an app-side responsibility, not a GitHub
Actions resource-build step.

Local Linux build:

```bash
flutter pub get
flutter analyze
flutter test
flutter build linux --debug --dart-define=PHIGROS_LIBRARY=.phigros_library
```

## Workflow

1. Install Python dependencies:

   ```bash
   python -m venv .venv
   .venv/bin/python -m pip install -r requirements.txt
   ```

   Or install into your current Python environment:

   ```bash
   python -m pip install UnityPy Pillow fsb5
   ```

   Check the local environment:

   ```bash
   .venv/bin/python tools/check_environment.py --network --flutter
   ```

2. Fetch and extract the latest APK resources:

   ```bash
   python tools/phigros_updater.py update --out .phigros_library
   ```

   The updater downloads to `.part` first, resumes interrupted downloads by
   default, verifies APK size/MD5 when TapTap provides them, writes
   `.phigros_library/manifest.json`, and removes stale files under `chart/`,
   `illustration/`, and `music/` after the new catalog is generated. It uses
   `tools/typetree.json` as the bundled upstream type tree cache and falls back
   to downloading the latest upstream copy when the cache is missing.

   Useful update variants:

   ```bash
   python tools/phigros_updater.py resolve-apk --out /tmp/phigros_latest.json
   python tools/phigros_updater.py update --apk /path/to/phigros.apk --metadata /tmp/phigros_latest.json --out .phigros_library
   python tools/phigros_updater.py update --apk /path/to/phigros.apk --typetree /path/to/typetree.json --out .phigros_library
   python tools/phigros_updater.py update --apk /path/to/phigros.apk --song '70MinutesFighters.かたぎり' --out .phigros_library
   python tools/phigros_updater.py update --out .phigros_library --catalog-only
   python tools/phigros_updater.py update --out .phigros_library --no-clean
   ```

   Validate generated resources:

   ```bash
   python tools/validate_library.py --library .phigros_library
   ```

3. Run the app against the extracted library:

   ```bash
   flutter pub get
   flutter run --dart-define=PHIGROS_LIBRARY=.phigros_library
   ```

   The app uses a Material You style layer and reads the catalog from
   `PHIGROS_LIBRARY/catalog/songs.json`. The sync action in the app can call the
   updater script on desktop/dev builds. Override the script or Python command
   when needed:

   ```bash
   flutter run \
     --dart-define=PHIGROS_LIBRARY=.phigros_library \
     --dart-define=PHIGROS_UPDATER=tools/phigros_updater.py \
     --dart-define=PYTHON=python
   ```

4. Generate Phira `.pez` packages:

   ```bash
   python tools/phira_export.py --library .phigros_library --out .phigros_library/phira
   ```

   By default, incomplete packages are skipped when chart, image, or music is
   missing. Use `--allow-incomplete` only when you explicitly want diagnostic
   packages.

The updater is data-driven: it reads `GameInformation` and Addressables from the APK so new songs and level counts are picked up without editing app code.
