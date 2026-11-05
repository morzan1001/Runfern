# Releases

`Version.xcconfig` is the shared version for the app and extensions. Set its version and build
number before tagging `v<version>`; `check-version.sh` rejects a mismatched tag.

```sh
RUNFERN_INTERNAL_BUILD=1 Tools/Build/build.sh jit build/v0.0.1-jit
RUNFERN_INTERNAL_BUILD=1 Tools/Build/build.sh appstore-archive build/v0.0.1-interpreter
```

Both commands verify signatures, the version and the variant's embedded components. The second
produces a signed Xcode archive only, without exporting or uploading it.
`RUNFERN_INTERNAL_BUILD=1` explicitly permits private validation despite unresolved licensing.
Without it, the build refuses to distribute anything until the
[license gate](../Licenses/README.md) is cleared. The CI pipeline never sets that flag.

The public JIT IPA is prepared with `package-sideload.sh`: it strips signatures and provisioning
profiles from a copy of the verified archive, leaving the signed originals private. Users must
re-sign it for their devices. Do not publish development archives or their device lists.

The **App Release** workflow runs only when a non-prerelease app release is published, never on
a push, pull request, edited release, Linux-base release or manual dispatch. Its release commit
must belong to `main`. It uses GitHub-hosted macOS runners with the iOS 27 SDK, and the audited
native runtime attached to that release (`Runfern-native-runtime.tar.gz` plus its `.sha256`).
Published releases are immutable, so stage everything on a draft first:

```sh
python3 Tools/Licenses/prepare.py --utm "$HOME/RunfernBuild/UTM"   # after a version bump; commit the result
gh release create v<version> --draft --target main --title "Runfern v<version>" --notes "…"
bash Tools/Build/stage-release.sh v<version>
```

`stage-release.sh` verifies the runtime and license artifacts locally, then attaches the
runtime archive and every file pinned in `Tools/Licenses/release-artifacts.json`. Publishing
the draft starts the workflow, which verifies all of them before importing signing credentials.
Only variants whose license gate passes are built. The JIT IPA is kept as a workflow artifact.

Release builds are disabled until the repository variable `ENABLE_RELEASE_BUILDS` is `true`.
Configure these secrets separately in the protected `sideload` and `appstore` environments:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded Apple Development (sideload) or Apple Distribution (appstore) certificate including its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password of that P12 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key identifiers |
| `ASC_PRIVATE_KEY` | Raw `.p8` API key contents |

Use minimum required App Store Connect permissions and restrict environment deployments to
`v*` tags, with a required reviewer and no administrator bypass. Network Extension provisioning
is required for built-in JIT; ordinary sideloading certificates cannot grant that capability.

TestFlight also requires `ENABLE_TESTFLIGHT_UPLOAD=true` and an independently confirmed
`APP_STORE_LICENSE_CLEARED=true` environment variable. Do not enable the latter merely because
a build passes: embedded GPL/LGPL components require separate assessment of Apple's distribution
terms, recorded as a sign-off in `Tools/Licenses/clearance.json`. The workflow does **not** submit an app for public App Store review. That stays manual.

No Apple credentials are committed or attached to release artifacts. Hosted runners install
them in a temporary keychain and remove them even on failure.

Uploads use Apple's supported
[altool interface](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds).
