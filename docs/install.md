# Installing xcmutate

There are three ways to get the tool: Homebrew, a build from source, or the archive of a release. Homebrew and the archive install the prebuilt binary of the latest release ([releases page](https://github.com/RyoHirota68/xcmutate/releases)).

## Homebrew

```bash
brew install RyoHirota68/tap/xcmutate
```

This installs the prebuilt executable of the latest release. Nothing is compiled. The executable is universal (arm64 and x86_64 in one file).

`brew install --HEAD RyoHirota68/tap/xcmutate` builds the main branch from source instead. That takes several minutes and needs Xcode 26.6 or newer.

`brew install`, `brew test`, `brew audit --strict --online` and `brew install --HEAD` were run on the published formula on 2026-11-24 (macOS 27, Xcode 27.2).

## What you need

To use the tool (any way of installing):

- macOS with Xcode: the full application, selected with `xcode-select`. The Command Line Tools alone are not enough, because the tool calls `xcodebuild`, `xcrun simctl` and `swiftc`.
- Runs were verified with Xcode 27.2 (macOS and an iOS simulator) and with Xcode 26.6 (a Swift package on macOS, and a small iOS app on a simulator, on GitHub-hosted runners). The prebuilt binary is built with Xcode 26.6; it was checked under Xcode 27.2 (the regression checks on macOS) and under Xcode 26.6 (on GitHub).
- `Package.swift` declares macOS 14 as the minimum platform. Only macOS 26 and 27 were tried.
- The project under test in a git repository. Outside one, `run` needs the Swift files named as arguments, and `--since` cannot be used.

To build it from source, in addition:

- Swift 6.3 or newer. The build was checked with Xcode 26.6 (Swift 6.3.3), on a Mac and on GitHub-hosted macOS runners, and with Xcode 27.2. An older Swift cannot build the package.

## From source

```bash
git clone https://github.com/RyoHirota68/xcmutate.git
cd xcmutate
swift build -c release            # several minutes the first time: swift-syntax is compiled
.build/release/xcmutate --version
```

The executable is one file and needs nothing beside it. Copy it to a directory on your `PATH`:

```bash
mkdir -p ~/.local/bin && cp .build/release/xcmutate ~/.local/bin/
```

`~/.local/bin` must be on your `PATH` (`export PATH="$HOME/.local/bin:$PATH"`). Any directory on the `PATH` that you can write to will do. `/usr/local/bin` belongs to root on Apple silicon Macs and needs `sudo`.

To update, `git pull`, build again and copy the file again.

## The release archive

This too needs a tagged release. Each release carries `xcmutate-<version>-macos-universal.tar.gz` and a `.sha256` file:

```bash
VERSION=0.14.0
curl -fsSLO "https://github.com/RyoHirota68/xcmutate/releases/download/v$VERSION/xcmutate-$VERSION-macos-universal.tar.gz"
curl -fsSLO "https://github.com/RyoHirota68/xcmutate/releases/download/v$VERSION/xcmutate-$VERSION-macos-universal.tar.gz.sha256"
shasum -a 256 -c "xcmutate-$VERSION-macos-universal.tar.gz.sha256"
tar -xzf "xcmutate-$VERSION-macos-universal.tar.gz"
mkdir -p ~/.local/bin && cp "xcmutate-$VERSION-macos-universal/xcmutate" ~/.local/bin/
```

The archive holds the executable, `LICENSE` and `THIRD_PARTY_NOTICES.md` (the licenses of swift-syntax and swift-argument-parser, which are linked into the executable).

The executable is signed ad hoc. It is not signed with a Developer ID and is not notarized.

- A file downloaded with `curl` runs as it is.
- A file downloaded with a browser gets the quarantine attribute, and macOS refuses to run it. Remove the attribute (`xattr -d com.apple.quarantine xcmutate`) or allow the file in System Settings.
- Homebrew does not set the attribute.

You can make the same archive yourself from a clone: `scripts/make-release.sh` builds it, checks it and prints its SHA-256.

## Mint

[Mint](https://github.com/yonaskolb/Mint) builds a Swift package's executable from a git reference, so it needs no release archive:

```bash
mint install RyoHirota68/xcmutate@<tag or commit>
mint run RyoHirota68/xcmutate xcmutate --version
```

This has not been tried. It builds from source, so it needs Swift 6.3 or newer.

## In CI

The GitHub Action installs the tool by itself: the release binary, or a build from source that is cached. See [ci.md](ci.md). On another CI system, use one of the ways above in a step of the job and cache the executable.

## Uninstalling

Delete the executable, or run `brew uninstall xcmutate`.

The tool keeps work directories under `~/Library/Caches/xcmutate/`. `xcmutate clean --all` removes them; run it before you delete the executable, or delete that directory by hand.

Outside the directories you name on the command line, the tool writes only there. Two things happen on your simulators: the app under test is installed on the simulator you name, and `run --workers` creates worker simulators, which it deletes again.
