# Debut

**Release your Mac app outside the App Store, with one command.**

Debut signs your app, notarizes it with Apple, builds a designed DMG, publishes it to GitHub, then downloads the release and checks it the way your users' Macs will.

It works with a finished `.app`, so it doesn't matter what you built it with.

```sh
debut setup            # Apple key and certificate
debut doctor           # finds problems before Apple does
debut release 1.0.0    # sign, notarize, DMG, publish, verify
```

> Debut is early. It has shipped test apps, and hasn't been tried on many real projects yet.

## What you need

- A paid [Apple Developer account](https://developer.apple.com/programs/). Apple requires this for notarizing.
- macOS 14 or later, with Xcode or the Command Line Tools.
- [GitHub CLI](https://cli.github.com) (`gh`), logged in, for publishing.
- Python 3, used to build the DMG.

## Install

```sh
git clone https://github.com/andretmarques/debut.git
cd debut
swift build -c release
cp .build/release/debut /usr/local/bin/
```

## Set up

Run `debut setup`. Apple doesn't allow all of this to be automated, so it takes up to two visits to Apple's site:

1. **An access key.** Debut opens the page. Under **Team Keys**, generate a key with the **Developer** role and download it. Debut finds the file, then asks for the **Issuer ID**, the long one with dashes above the key list.
2. **A certificate, if you don't have one.** Debut prepares the request and opens the page. Upload the file it selected, then download the result. Debut installs it.

The key is saved in your Keychain. You can do this once and forget it, apart from renewing the certificate when Debut warns you.

## Release

```sh
debut release 1.0.0 --app build/MyApp.app
```

The version must match the app's `Info.plist`, and Debut won't replace an existing release. To skip GitHub, add `--no-publish`.

To name a release, add `ReleaseNotes/1.0.0.md`:

```md
# Clean Edge

What's new in this release.
```

Project defaults can live in `debut.json`:

```json
{
  "app": "build/MyApp.app",
  "build": "./build.sh",
  "repository": "you/myapp"
}
```

## Doctor

`debut doctor --app build/MyApp.app` checks for problems that are easy to miss:

- Nested apps with no icon, which show up generically in System Settings
- Icons that macOS 26 may put on a grey plate
- Missing or broken signatures, and a missing hardened runtime
- Parts of an app signed by different teams
- A certificate that's expired or about to

Add `--before-signing` to skip the signature checks.

## GitHub Actions

On your Mac, send the secrets to your repo. They're never printed, and only your Developer ID certificate is exported:

```sh
debut setup --github you/myapp
```

Then add this to a workflow on a macOS runner:

```yaml
permissions:
  contents: write

jobs:
  release:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: ./build.sh
      - uses: andretmarques/debut@v0.1.1
        with:
          version: ${{ inputs.version }}
          app: build/MyApp.app
          key-id: ${{ secrets.DEBUT_KEY_ID }}
          issuer-id: ${{ secrets.DEBUT_ISSUER_ID }}
          key: ${{ secrets.DEBUT_KEY }}
          certificate: ${{ secrets.DEBUT_CERT_P12 }}
          certificate-password: ${{ secrets.DEBUT_CERT_PASSWORD }}
```

Debut runs on your own runner, so your signing keys stay in your repo's secrets and never pass through a Debut server. There isn't one.

## License

[MIT](LICENSE)
