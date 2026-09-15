# Releasing Arena

Pushing a stable semantic-version tag such as `v0.1.0` runs the GitHub release workflow. It builds a universal macOS app, signs it with Developer ID, notarizes it with Apple, staples the notarization ticket, verifies it with Gatekeeper, and publishes a ZIP and SHA-256 checksum to GitHub Releases.

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

Do not commit any of these values. A provisioning profile is not required because Arena does not use restricted app services.

Apple's guides cover [Developer ID certificate creation](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) and the [`notarytool` workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). GitHub documents [storing and importing a `.p12` with Actions secrets](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Publish a release

Make sure the release commit is on `main`, then create and push an annotated tag:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "Arena 0.1.0"
git push origin v0.1.0
```

The tag supplies `CFBundleShortVersionString`; the GitHub run number supplies `CFBundleVersion`. The workflow publishes only after signing and notarization succeed. Use a new version tag to retry after fixing source or workflow problems; release tags should not be moved.
