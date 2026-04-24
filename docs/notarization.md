# Signing & notarization

This document describes how signed + notarized releases are produced, and how contributors can sign their own local builds. Local and source builds stay un-hardened and unsigned-by-default so contributors without Apple Developer credentials can still build from source — notarization only runs in CI on tag pushes.

## Why hardened runtime is off by default

`ENABLE_HARDENED_RUNTIME=NO` is the repo default (`project.yml`). Hardened runtime blocks Apple-event delivery by default, so every fresh build of a hardened app would prompt for Terminal/iTerm2 automation permission the first time you click a tile. That's fine for a shipped binary (the user approves once per terminal app) but painful when you're rebuilding constantly. The release workflow overrides the setting to `YES` only for CI-produced artifacts.

## Local signing — xcconfig layer

The `Configuration/` directory lets each contributor set their own Developer Team without touching `project.yml`:

```
Configuration/
├── Base.xcconfig                   # committed — default APP_BUNDLE_ID + Automatic signing, no team
├── LocalSigning.xcconfig.example   # committed — template
└── LocalSigning.xcconfig           # gitignored — your personal overrides
```

`Base.xcconfig` defaults `APP_BUNDLE_ID = com.cliqconsulting.claudemonitor` and leaves `DEVELOPMENT_TEAM` empty. It ends with `#include? "LocalSigning.xcconfig"`, so if a `LocalSigning.xcconfig` exists in the same directory its values override the defaults.

`project.yml` wires `Configuration/Base.xcconfig` into every target's `configFiles` (both Debug and Release) and resolves each target's `PRODUCT_BUNDLE_IDENTIFIER` from `$(APP_BUNDLE_ID)` (e.g. `$(APP_BUNDLE_ID).tests` for the unit-test bundle).

To sign with your own team:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
# edit to set DEVELOPMENT_TEAM; optionally override APP_BUNDLE_ID
make gen
```

Contributors who don't set `DEVELOPMENT_TEAM` get the same Automatic-signing prompts they would with any open-source Xcode project, and the app still builds.

## CI notarization

The release workflow (`.github/workflows/release.yml`) runs on `v*` tag pushes. It ignores the xcconfig layer by passing `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM`, and `ENABLE_HARDENED_RUNTIME=YES` directly on the `xcodebuild` command line (xcodebuild args beat xcconfig).

### Prerequisites (one-time, in Apple's portals)

1. **Register the App ID** `com.cliqconsulting.claudemonitor` under the Cliq Consulting team at [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list). Notarytool rejects submissions whose bundle ID the submitting team doesn't own.
2. **Install a Developer ID Application certificate** for the Cliq team in your local Keychain. If there isn't one, create it from [Certificates](https://developer.apple.com/account/resources/certificates/list) → *+ → Developer ID Application*, then download and double-click to install.

### Repository secrets (seven)

All secrets live at `https://github.com/cliq/claude-monitor/settings/secrets/actions`.

#### Developer ID cert

Keychain Access → *My Certificates* → right-click "Developer ID Application: Cliq Consulting LLC (…)" → **Export…** → save as `devid.p12` with a password.

```sh
base64 -i devid.p12 | pbcopy            # paste as BUILD_CERTIFICATE_BASE64
```

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | base64 of `devid.p12` |
| `P12_PASSWORD` | the password you set on export |
| `KEYCHAIN_PASSWORD` | any string; unlocks a throwaway keychain on the CI runner |
| `TEAM_ID` | 10-char Team ID from [developer.apple.com → Membership](https://developer.apple.com/account/#MembershipDetailsSection) |

#### Notarytool API key

[App Store Connect → Users and Access → Integrations → Keys](https://appstoreconnect.apple.com/access/api) → **+** → **Developer** role. Download the `.p8` **immediately** — it can't be re-downloaded.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy  # paste as NOTARY_KEY_BASE64
```

| Secret | Value |
|---|---|
| `NOTARY_KEY_BASE64` | base64 of the `.p8` |
| `NOTARY_KEY_ID` | 10-char key ID shown next to the key in ASC |
| `NOTARY_ISSUER_ID` | issuer UUID at the top of the Keys tab |

## Cutting a release

Once the secrets and code changes are on `main`:

1. Move or create the tag on the commit you want to ship: `git tag -a vX.Y -m vX.Y && git push origin vX.Y`. The workflow fires only when the tag is pushed *after* the workflow file is on main.
2. Watch **Actions**. First run usually fails on something specific — wrong `TEAM_ID`, cert import, or notarytool auth — and the log points at it.
3. On success, a stapled `ClaudeMonitor.dmg` is attached to the corresponding GitHub Release.

## Verifying the downloaded DMG

```sh
xcrun stapler validate ~/Downloads/ClaudeMonitor.dmg
spctl -a -vv -t install ~/Downloads/ClaudeMonitor.dmg
```

Both should report accepted / notarized. The first tile click after install triggers the standard "Claude Monitor wants to control Terminal.app / iTerm2" TCC prompt — approve once per terminal app.
