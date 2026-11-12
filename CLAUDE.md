# Debut

Debut releases a finished Mac `.app` outside the App Store with one command ([README.md](README.md)).

## Where things live

| Target | Job | Path |
| --- | --- | --- |
| `DebutCore` | Pure logic, no I/O. | [Sources/DebutCore](Sources/DebutCore) |
| `DebutSystem` | All I/O: shell, disk, Apple, GitHub. | [Sources/DebutSystem](Sources/DebutSystem) |
| `debut` | The command-line executable: `setup`, `doctor`, `release`, and `ci-keychain` for the GitHub Action. | [Sources/debut](Sources/debut) |
| `DebutCoreTests` | The only tests. `DebutSystem` and `debut` have none. | [Tests/DebutCoreTests](Tests/DebutCoreTests) |
| GitHub Action | Composite action that builds Debut and runs `debut release`. The calling job must run on macOS. | [action.yml](action.yml) |

## Commands

- Build: `swift build`
- Test: `swift test`. On a Mac with Command Line Tools and no Xcode, the Swift Testing macro plugin is not found, so run `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.
- Release build and install: `swift build -c release`, then use `.build/release/debut` (see [README.md](README.md#install)).
- `debut setup` and `debut release`: ask André before running either. They use his Apple key and certificate, and `release` publishes to the repo `gh` finds in the current folder. There is no dry run: unknown flags are ignored, and `--no-publish` still signs and notarizes.

## Status

Project status lives in [README.md](README.md), in the note under the usage example.

Debut's own versions are git tags (`git tag --list 'v*.*.*' --sort=-v:refname | head -1` is the latest). No file says how to cut one, so ask André before tagging.
