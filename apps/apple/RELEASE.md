# Releasing the native Apple apps

Three apps ship from `apps/apple`. Each one has a fastlane lane in `fastlane/Fastfile`, backed by
the scripts in `scripts/release/`. The `Apple release` workflow
(`.github/workflows/apple-release.yml`) runs the same lanes in CI.

| App | Scheme | Bundle id | Distribution | Lane |
|---|---|---|---|---|
| Omnigent for Mac (Developer ID) | `OmnigentMac` | `ai.omnigent.mac` | notarized DMG, plus Sparkle updates | `mac developer_id` |
| Omnigent for Mac (App Store) | `OmnigentMacAppStore` | `ai.omnigent.mac.appstore` | Mac App Store | `mac app_store` |
| Omnigent for iPhone and iPad | `Omnigent` | `ai.omnigent.ios` | TestFlight, App Store | `ios beta`, `ios release` |

The `.lab` bundle ids (`ai.omnigent.mac.lab` and the others) belong to Debug builds and never ship.

The Electron desktop app (`web/electron`, `ai.omnigent.desktop`) and the WKWebView iOS shell
(`web/ios`) keep their own runbooks (`web/electron/RELEASING.md` and `web/ios/RELEASE.md`). Two
things are shared with them:

- **`ai.omnigent.ios` is the web shell's App Store record.** A native iOS upload goes to the
  same app and the same build-number sequence. The `latest + 1` rule keeps the two pipelines
  from colliding. Shipping the native app to the App Store replaces the web shell, and its
  marketing version must be higher than the shell's latest released version.
- **The Developer ID app is named `Omnigent.app`, the same as the Electron app.** Both install
  into `/Applications`, so decide on the migration (rename, or replace and migrate settings)
  before the first public Developer ID release.

## One-time setup

1. **Xcode 27.2, Rust, mise and just**, as in `README.md`.
2. **fastlane**, pinned by `Gemfile.lock` (the same lock as `web/ios`; bump the two together):
   ```sh
   cd apps/apple
   bundle install
   bundle exec fastlane lanes
   ```
3. **App Store Connect API key** (Users and Access > Integrations > App Store Connect API, role
   App Manager). The same key handles uploads, build numbers and notarization. Download the
   `.p8` once.
   ```sh
   cp fastlane/.env.example fastlane/.env   # set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
   ```
   `.env`, `AuthKey_*.p8` and fastlane's run output are git-ignored (`fastlane/.gitignore`). The
   lanes also accept web/ios's `APPLE_API_KEY_ID`, `APPLE_API_ISSUER` and `APPLE_API_KEY` names.
4. **App records** in App Store Connect: `ai.omnigent.mac.appstore` is new (a macOS app);
   `ai.omnigent.ios` already exists.
5. **Certificates** for team `8RMX4WU6F8` (Databricks, Inc.):

   | Certificate | Used by |
   |---|---|
   | Developer ID Application | `mac developer_id`: the app, web host, CEF, helpers, Sparkle and the DMG |
   | Apple Distribution | `mac app_store` (the app) and `ios` |
   | Mac Installer Distribution (3rd Party Mac Developer Installer) | `mac app_store` (the `.pkg`) |

6. **Provisioning profiles.** The Developer ID edition needs none: it uses no restricted
   entitlements, so codesign signs it directly. Each store app needs an App Store distribution
   profile:

   | Profile | Bundle id | CI secret |
   |---|---|---|
   | Mac App Store distribution | `ai.omnigent.mac.appstore` | `MAC_APP_STORE_PROVISIONING_PROFILE_BASE64` |
   | iOS App Store distribution | `ai.omnigent.ios` | `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64` |

   On a release Mac signed into Xcode, leave `OMNIGENT_*_PROFILE_PATH` unset. Automatic signing
   then fetches the profiles itself (`-allowProvisioningUpdates` with the API key). In CI the
   lane installs the profile from the secret and switches only the app target of the generated
   `Omnigent.xcodeproj` to manual signing.
7. **Sparkle EdDSA key**, for the Developer ID edition only. See [Auto-update](#auto-update-developer-id-edition).

## Versioning

- **Marketing version** (`CFBundleShortVersionString`): one value for all three apps,
  `Omnigent.marketingVersion` in `Tuist/ProjectDescriptionHelpers/OmnigentSettings.swift`. Bump
  it in a PR before a release. A release tag must match it: `apple-v<marketingVersion>`, for
  example `apple-v0.2.0`. The lanes fail on a mismatch.
- **Build number** (`CFBundleVersion`): computed for each upload, never committed:
  - iOS: `latest_testflight_build_number(ai.omnigent.ios) + 1`, as in `web/ios`.
  - Mac App Store: `latest_testflight_build_number(ai.omnigent.mac.appstore, osx) + 1`.
  - Developer ID: the newest `sparkle:version` in the live appcast + 1, because that is the
    number Sparkle compares. `OMNIGENT_BUILD_NUMBER` overrides it, which only the first release
    needs. `generate-appcast.sh` refuses a build that is not newer than the feed.
- **Injection.** Both values reach every target, the web host and its helpers included, as the
  xcodebuild overrides `MARKETING_VERSION=` and `CURRENT_PROJECT_VERSION=`. The Info.plists read
  `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`. Nothing in the repo changes, and
  `archive-mac-developer-id.sh` checks the archived bundles carry the injected values.

## Cutting a release

1. Merge the `marketingVersion` bump and record the merge commit.
2. Tag it and push the tag:
   ```sh
   git tag apple-v0.2.0 <merge-sha>
   git push origin apple-v0.2.0
   ```
   The tag runs every job of `Apple release`: Developer ID, Mac App Store, and iOS through the
   `beta` lane (TestFlight). Every job waits for approval of the `apple-release` environment.
3. To run one app, or iOS through `release` instead of `beta`, dispatch the workflow manually:
   ```sh
   gh workflow run apple-release.yml --ref apple-v0.2.0 -f targets=ios -f ios-lane=release
   ```
4. **Developer ID:** download the `omnigent-mac-developer-id-<run>` artifact and publish it (see
   [Publish the Developer ID release](#publish-the-developer-id-release)). Uploads to the stores
   need no further step until review submission, which these lanes never do.

The same lanes run locally from `apps/apple` with the variables from `fastlane/.env`:

```sh
bundle exec fastlane mac developer_id
bundle exec fastlane mac app_store
bundle exec fastlane ios beta        # or: ios release
```

All of them accept `skip_prereqs:true` to reuse an already generated workspace.

## Developer ID edition (`mac developer_id`)

1. **Build** (`archive-mac-developer-id.sh`):
   - `scripts/build-core.sh release`: universal macOS core xcframework and bindings.
   - `scripts/fetch-cef.sh --arch universal`.
   - `tuist install` and `tuist generate`, which also writes the helper entitlements to
     `Derived/Entitlements`.
   - `xcodebuild archive` of `OmnigentMac` (Release, `CODE_SIGNING_ALLOWED=NO`, both archs).
   - It checks that the web host and CEF are embedded, that the injected versions are present,
     and that every Mach-O has both architectures.
2. **Sign inside-out** (`sign-mac-developer-id.sh`), on a copy of the archived app, with
   hardened runtime and a secure timestamp:
   1. the Chromium Embedded Framework's `Libraries/*.dylib`, then the framework
   2. the five helpers, `Omnigent Web Host Helper`, `(GPU)`, `(Renderer)`, `(Plugin)` and
      `(Alerts)`, each with its entitlements from `BrowserTargets.helperVariants` (allow-jit
      for the base, GPU and Renderer helpers; unsigned executable memory and disabled library
      validation for Plugin; none for Alerts)
   3. `Contents/Helpers/Omnigent Web Host.app`, which has no entitlements
   4. the app's own frameworks: Sparkle's `Autoupdate`, `Updater.app` and XPC services (each
      keeps its entitlements), then `Sparkle.framework`
   5. `Omnigent.app`, with `OmnigentMac.entitlements` (no App Sandbox)

   The script then fails on any Mach-O that is unsigned or signed by another team. It also
   refuses unknown nested code, such as new `PlugIns` or `XPCServices`, until the script is
   taught to sign it.
3. **Verify** (`verify-mac-developer-id.sh`): `codesign --verify --deep --strict`, hardened
   runtime on the app, the host and each helper, the exact helper entitlements, and no App
   Sandbox.
4. **Notarize** (`notarize.sh`): `notarytool submit --wait` with the API key. The script prints
   the notary log and fails unless the verdict is `Accepted`. It then staples the app, and
   `verify-mac-developer-id.sh --notarized` adds `spctl --assess` and `stapler validate`.
5. **Package** (`package-mac-developer-id.sh`), from the stapled app:
   - `Omnigent-<version>-<build>.zip` (`ditto --sequesterRsrc --keepParent`): the Sparkle update.
   - `Omnigent-<version>-<build>.dmg`, with an `/Applications` link, signed, then notarized and
     stapled. The lane then runs `spctl --assess --type open` on the DMG.
6. **Appcast** (`generate-appcast.sh`; see below).

Outputs are in `build/release/developer-id/dist/`. The archive in `build/release/developer-id/`
keeps the dSYMs.

### Dry run without signing identities

```sh
OMNIGENT_BUILD_NUMBER=1 bundle exec fastlane mac developer_id adhoc:true
# host-arch only, against an already generated workspace:
bundle exec fastlane mac developer_id adhoc:true skip_prereqs:true archs:arm64
```

`adhoc:true` signs inside-out with the ad-hoc identity (`-`), with no timestamp, and runs the
codesign verification. It skips notarization, Gatekeeper (which rejects ad-hoc code by design)
and the appcast. It still produces the zip and the DMG.

## Auto-update (Developer ID edition)

Sparkle 2 (`2.10.1`, EdDSA-signed appcast) updates only the Developer ID edition. The App Store
updates the App Store edition, which must never contain Sparkle: App Review rejects
self-updaters. `check-mac-app-store.sh` fails the `app_store` lane if Sparkle or Chromium
appears in that bundle.

### Hosting

Next to the Electron feed (`https://omnigent.ai/_desktop/updates/`, `latest-mac.yml`), but on
its own path, because the app, the bundle id and the update client all differ:

| What | Where |
|---|---|
| Appcast | `https://omnigent.ai/_desktop/updates/native/mac/appcast.xml`, which is `public/_desktop/updates/native/mac/appcast.xml` in `omnigent-site` |
| Update zips and DMGs | the `omnigent-builds` Vercel Blob store, under `native-mac/Omnigent-<version>-<build>.{zip,dmg}` |
| Download links | `omnigent-site` redirects `/download/native-mac` (latest DMG) and `/download/native-mac/v<version>` |

`OMNIGENT_SPARKLE_DOWNLOAD_URL_PREFIX` (a repository variable) is the Blob URL prefix, ending in
`native-mac/`. As with the Electron release, the binaries are uploaded create-only, and merging
the site PR makes a release live.

### Keys

- Generate the EdDSA key pair once, on a trusted Mac, with Sparkle's `generate_keys` (from
  `scripts/release/fetch-sparkle-tools.sh`). Export the private key with
  `generate_keys -x private-key.txt` and store its contents as the `SPARKLE_ED_PRIVATE_KEY`
  secret of the `apple-release` environment. Then delete the file, and remove the key from the
  login keychain if that Mac is not a release machine. Keep an offline backup in the team's
  secret manager. Losing the key means shipped apps can never update again.
- The **public** key is not secret. It goes into `OmnigentMac`'s Info.plist as `SUPublicEDKey`
  (see below). `generate-appcast.sh` derives the public half of `SPARKLE_ED_PRIVATE_KEY` and
  fails unless it equals the archived app's `SUPublicEDKey`. The private key reaches Sparkle's
  tools only on stdin, never in argv or a file.

### Appcast generation

`generate-appcast.sh` runs in the `developer_id` lane after the DMG is notarized:

1. It fetches the pinned Sparkle tools (`fetch-sparkle-tools.sh`, checked by SHA-256).
2. It downloads the live appcast (or starts a new feed with `OMNIGENT_SPARKLE_NEW_FEED=1` on the
   first release) and checks that the new build is newer than every item in it.
3. `generate_appcast` adds the new item, signs the zip with EdDSA, and embeds the Markdown
   release notes from `OMNIGENT_RELEASE_NOTES`. It keeps the last 10 items.
4. The script checks that the new item points at `<prefix>Omnigent-<version>-<build>.zip` and
   that its signature verifies (`sign_update --verify`).

### App integration

The updater lives in
`Packages/OmnigentDesktop/Sources/OmnigentDesktop/Update/SparkleUpdater.swift` and is inert until
Sparkle is wired in. Wiring it in takes three changes:

1. **`Packages/OmnigentDesktop/Package.swift`:** a separate product, so the App Store edition
   never links Sparkle.
   ```swift
   dependencies: [
     .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
   ],
   products: [
     .library(name: "OmnigentDesktop", targets: ["OmnigentDesktop"]),
     .library(name: "OmnigentDesktopUpdate", targets: ["OmnigentDesktopUpdate"]),
     // ...
   ],
   targets: [
     .target(name: "OmnigentDesktop", exclude: ["Update"], swiftSettings: mainActorSwiftSettings),
     .target(
       name: "OmnigentDesktopUpdate",
       dependencies: [.product(name: "Sparkle", package: "Sparkle")],
       path: "Sources/OmnigentDesktop/Update",
       swiftSettings: mainActorSwiftSettings),
     // ...
   ]
   ```
   Keep `exact:` equal to `SPARKLE_VERSION` in `scripts/release/fetch-sparkle-tools.sh`.
2. **`Project.swift`:** `OmnigentMac` only, never `OmnigentMacAppStore`:
   ```swift
   // macApp.dependencies
   .package(product: "OmnigentDesktopUpdate"),
   // macApp infoPlist: Omnigent.infoPlist(extra: macInfoPlistShared.merging([
   "SUFeedURL": "https://omnigent.ai/_desktop/updates/native/mac/appcast.xml",
   "SUPublicEDKey": "<base64 public EdDSA key>",
   "SUEnableAutomaticChecks": true,
   // ]) { _, new in new })
   ```
   Sparkle embeds as `Contents/Frameworks/Sparkle.framework`. `sign-mac-developer-id.sh`
   already signs its nested code.

   These three changes are in place. `SUPublicEDKey` is an empty placeholder in `Project.swift`
   (`sparkleInfoPlist`) until the release key pair exists, so no update can be verified. When
   Sparkle reports a start or update failure, the app logs it and shows it under Settings >
   General > Updates. Set the key to the base64 public key before the first Developer ID
   release.
3. **`OmnigentMacApp.swift`** (`OMNIGENT_CHROMIUM` builds only): create
   `SparkleUpdater(reportIssue:)` in the app delegate, call `try updater.start()` in
   `applicationDidFinishLaunching` and surface any thrown error, and pass
   `checkForUpdates: updater.checkForUpdates` to `DesktopCommandActions`. The item stays hidden
   in the App Store edition, where the closure is `nil`.

### Keychain entitlement

Both Mac editions' Release entitlements carry `keychain-access-groups` with the app's own
application identifier (`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`), which the
data-protection keychain needs for saved sign-ins. Release signing therefore needs a
provisioning profile for the bundle id (Developer ID or Mac App Store). Ad-hoc Debug builds use
the `*-Debug.entitlements` files without the group and keep credentials in files only the user
can read (`KeychainModeSelection`). A Release build falls back the same way only when it has no
team ID (the local build from `scripts/install-local-release.sh`); a team-signed Release never
falls back.

### Publish the Developer ID release

From the `omnigent-mac-developer-id-<run>` artifact, mirroring steps 4 and 5 of
`web/electron/RELEASING.md`:

1. Check that the DMG is stapled and accepted by Gatekeeper:
   `xcrun stapler validate Omnigent-<v>-<b>.dmg` and `spctl -a -t open --context context:primary-signature -vv Omnigent-<v>-<b>.dmg`.
2. Upload the zip and the DMG to Blob under `native-mac/`, create-only. Stop if either path
   already exists.
3. In an `omnigent-site` PR, replace `public/_desktop/updates/native/mac/appcast.xml` with the
   artifact's `appcast.xml` and repoint `/download/native-mac`. Merging the PR ships the update.

## Mac App Store edition (`mac app_store`)

1. Universal release core and `tuist generate`. No CEF is needed.
2. `xcodebuild archive` of `OmnigentMacAppStore` with the computed versions.
3. `check-mac-app-store.sh` on the archived app, which runs `WebHost/Scripts/check-no-chromium.sh`
   (the same check as the target's build phase), checks that Sparkle is absent, and checks that
   the app is signed with App Sandbox.
4. Export with the `app-store` method (`build_mac_app`, from the existing archive) into a signed
   `.pkg`.
5. `upload_to_app_store(platform: "osx", submit_for_review: false)`, with no metadata and no
   screenshots. Submit for review in App Store Connect.

## iOS (`ios beta`, `ios release`)

These mirror `web/ios`'s `beta` and `release` lanes: release core and `tuist generate`, then an
archive of `Omnigent`, an App Store export, and `upload_to_testflight` (`beta`) or
`upload_to_app_store` without submission (`release`). Store metadata, screenshots and the `prod`
lane stay in `web/ios` until the native app takes over the record.

## CI secrets and variables

All of them live in the `apple-release` GitHub environment. Protect it with required reviewers
and restrict it to `apple-v*` tags and `main`.

| Name | Kind | Jobs | Contents |
|---|---|---|---|
| `ASC_KEY_ID` | secret | all | App Store Connect API key id |
| `ASC_ISSUER_ID` | secret | all | API key issuer id |
| `ASC_KEY_P8_BASE64` | secret | all | `base64 -i AuthKey_<id>.p8` |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | secret | Developer ID | Developer ID Application certificate and private key, `.p12`, base64 |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | secret | Developer ID | its export password |
| `APPLE_DISTRIBUTION_P12_BASE64` | secret | Mac App Store, iOS | Apple Distribution certificate, `.p12`, base64 |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | secret | Mac App Store, iOS | its export password |
| `MAC_INSTALLER_DISTRIBUTION_P12_BASE64` | secret | Mac App Store | Mac Installer Distribution certificate, `.p12`, base64 |
| `MAC_INSTALLER_DISTRIBUTION_P12_PASSWORD` | secret | Mac App Store | its export password |
| `MAC_APP_STORE_PROVISIONING_PROFILE_BASE64` | secret | Mac App Store | `.provisionprofile`, base64 |
| `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64` | secret | iOS | `.mobileprovision`, base64 |
| `SPARKLE_ED_PRIVATE_KEY` | secret | Developer ID | output of `generate_keys -x` (base64 EdDSA private key) |
| `OMNIGENT_SPARKLE_DOWNLOAD_URL_PREFIX` | variable | Developer ID | Blob URL prefix ending in `native-mac/` |

Each job imports its certificates into a temporary keychain (`scripts/release/ci-keychain.sh`,
which reads the secrets from environment variables by name). It writes the `.p8` and profiles
to `$RUNNER_TEMP`, and deletes all of them in an `always()` step. Encode the files with
`base64 -i <file> | pbcopy`.

## Rollback

- **Developer ID.** Sparkle never downgrades.
  - To stop a bad update from spreading, revert `appcast.xml` in `omnigent-site` to the
    previous version and merge. Users who have not updated yet stop seeing it.
  - To fix users who already updated, ship a roll-forward: the previous good source with a
    newer build number (a normal release from that commit). Bump the patch version if the
    marketing version must change.
  - Leave the bad binaries in Blob, because uploads are create-only, and repoint
    `/download/native-mac` to the previous DMG.
  - If a key or certificate is compromised, revoke the Developer ID certificate (Gatekeeper
    then blocks the signed builds) and rotate `SPARKLE_ED_PRIVATE_KEY` only through a release
    signed with the old key that carries the new `SUPublicEDKey`.
- **Mac App Store and iOS.** A store build cannot be pulled from devices.
  - Before release, reject the build in App Store Connect or expire it in TestFlight.
  - After release, pause the phased release if one is running, or remove the version from
    sale, then ship a fixed build with the next build number.
- **Failed run.** The lanes compute a fresh build number on every run, so re-running a failed
  job is safe. App Store Connect rejects a duplicate build number rather than overwriting it.

## Local checks

```sh
shellcheck -x apps/apple/scripts/release/*.sh
actionlint .github/workflows/apple-release.yml   # only `xcode-27` is reported, a custom image label
(cd apps/apple && bundle exec fastlane lanes)
```
