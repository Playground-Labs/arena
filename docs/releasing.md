# Releasing Arena

Pushing a stable semantic-version tag such as `v0.1.0` runs the GitHub release workflow. It builds a universal macOS app, signs it with Developer ID, notarizes it with Apple, staples the notarization ticket, verifies it with Gatekeeper, and publishes a ZIP and SHA-256 checksum to GitHub Releases. It also publishes a Sparkle appcast so installed copies can update themselves in-app.

## One-time GitHub setup

You need an active Apple Developer Program membership and a **Developer ID Application** certificate. Export the certificate and its private key from Keychain Access as a password-protected `.p12` file.

Add these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | The exported `.p12`, encoded with `base64 -i DeveloperID.p12 | pbcopy`. |
| `P12_PASSWORD` | The password used when exporting the `.p12`. |
| `APPLE_ID` | The Apple Account email used for notarization. |
| `APPLE_TEAM_ID` | The 10-character Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password created for the Apple Account. |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle EdDSA private key, exported with `generate_keys -x` (see below). |

Do not commit any of these values. A provisioning profile is not required because Arena does not use restricted app services.

## Sparkle update signing

Every update is signed with an EdDSA key pair, created once. Download the Sparkle tools matching `SPARKLE_VERSION` in the workflow, currently [`Sparkle-2.9.6.tar.xz`](https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz), then:

```sh
bin/generate_keys --account Arena
bin/generate_keys --account Arena -x sparkle-ed.key
```

The first command stores the private key in your login keychain and prints the public key, which lives in `Sources/Arena/Info.plist` as `SUPublicEDKey`. The second exports the private key for the `SPARKLE_ED_PRIVATE_KEY` secret; delete `sparkle-ed.key` once the secret is saved.

Keep the private key. Losing or rotating it breaks in-app updates for every installed copy, and those users would have to download Arena manually once more.

Apple's guides cover [Developer ID certificate creation](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) and the [`notarytool` workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). GitHub documents [storing and importing a `.p12` with Actions secrets](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Publish a release

Make sure the release commit is on `main`, then create and push an annotated tag:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "Arena 0.1.0"
git push origin v0.1.0
```

The release includes `appcast.xml`, which the app fetches from `https://github.com/Playground-Labs/arena/releases/latest/download/appcast.xml`; the workflow only ever publishes stable releases. The tag supplies `CFBundleShortVersionString`; the GitHub run number supplies `CFBundleVersion`, which Sparkle compares to decide whether an update is newer, so do not rename or recreate `release.yml` (that resets the run number and installed copies would stop seeing updates). The workflow publishes only after signing and notarization succeed. Use a new version tag to retry after fixing source or workflow problems; release tags should not be moved.
