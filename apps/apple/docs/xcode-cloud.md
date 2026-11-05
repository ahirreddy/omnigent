# Xcode Cloud

Xcode Cloud builds and tests the iOS app (`Omnigent` scheme) and the Mac app (`OmnigentMac`)
on Apple's machines, so UI tests on many simulators don't load a local Mac.

## What the scripts do

`apps/apple/ci_scripts/` sits next to `Omnigent.xcworkspace`, where Xcode Cloud looks for it.

- `ci_post_clone.sh` runs on the build machine. It installs the pinned Rust toolchain and the
  mise tools (tuist, swiftlint, zig), builds the Rust core, fetches libghostty (and CEF for
  macOS), then runs `tuist install` and `tuist generate`. These are the same steps as
  `.github/workflows/client.yml`.
- `ci_pre_xcodebuild.sh` runs before `test-without-building`. Test machines receive only
  `ci_scripts`, so it downloads the commit's source from GitHub and starts the loopback test
  stack: the API on 127.0.0.1:6767, the mock model on 6796, a registered host, and seeded
  fixtures.
  - The source repository comes from `OMNIGENT_SOURCE_REPO` and defaults to
    `ahirreddy/omnigent`. It must be public.
  - Set `OMNIGENT_CI_SKIP_TEST_STACK=1` to skip the stack.

## Building under a personal team

The project signs with team `8RMX4WU6F8` and bundle IDs `ai.omnigent.*`. Another team can't
register those IDs, so the Tuist manifest takes two overrides:

| Variable | Default | Effect |
| --- | --- | --- |
| `TUIST_OMNIGENT_TEAM_ID` | `8RMX4WU6F8` (on Xcode Cloud: the workflow's `CI_TEAM_ID`) | `DEVELOPMENT_TEAM` |
| `TUIST_OMNIGENT_BUNDLE_ID_PREFIX` | `ai.omnigent` | prefix of every bundle ID, e.g. `com.example.omnigent.ios` |

## One-time setup

You need a paid Apple Developer Program membership. Creating the App Store Connect app records
also needs the Account Holder or Admin role.

1. Generate the workspace locally with your team and prefix, then open it:

   ```bash
   cd apps/apple
   TUIST_OMNIGENT_TEAM_ID=<TEAM_ID> TUIST_OMNIGENT_BUNDLE_ID_PREFIX=com.<you>.omnigent \
     mise exec -- tuist generate
   ```

2. In Xcode, sign in with your Apple ID under Settings > Accounts.
3. Choose Integrate > Create Workflow and pick the `Omnigent` product.
   - Xcode creates the App Store Connect app (`com.<you>.omnigent.ios`).
   - It asks you to grant Xcode Cloud access to the GitHub repository (`ahirreddy/omnigent`).
4. Edit the workflow:
   - **Environment:** Xcode 27.2, the version Tuist pins. Add the variable
     `TUIST_OMNIGENT_BUNDLE_ID_PREFIX=com.<you>.omnigent`.
   - **Start conditions:** Branch Changes on `apple-native-scaffold`, plus manual starts.
   - **Actions:** Test, scheme `Omnigent`, destinations iPhone and iPad simulators on the
     latest iOS.
5. Repeat with the `OmnigentMac` product: a Test action on macOS. Add the same variable to its
   environment.
6. Optional, so an agent can start builds and read results without Xcode: create an App Store
   Connect API key.
   - In Users and Access > Integrations > Team Keys, create a key with the Developer role.
   - Keep the `.p8` file outside the repository, for example in
     `~/.appstoreconnect/private_keys/`.
   - Share the key ID and issuer ID.

## Cost

Apple Developer Program membership includes 25 compute hours a month. Each test destination
counts separately. A cold run spends most of its time on the Rust core, libghostty and (on
macOS) CEF, because Xcode Cloud keeps no cache between builds.
