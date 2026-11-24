#!/bin/bash
# Step of the GitHub Action (action.yml): puts the xcmutate executable into $TOOL_DIR/bin and that on the PATH.
#
#   install.sh key      prints what the tool's cache is keyed by (to $GITHUB_OUTPUT as `key`)
#   install.sh install  uses the cached executable, or downloads the release binary, or builds from the sources
#
# Environment: INPUT_VERSION ("" | "source" | <version>), ACTION_REF (the ref the action was called with),
# ACTION_PATH (the checkout of the action), ACTION_REPOSITORY (<owner>/<name>), TOOL_DIR, GH_TOKEN (optional).
set -euo pipefail

MODE="${1:-install}"
VERSION="${INPUT_VERSION:-}"
VERSION="${VERSION#v}"                 # "v0.13.0" and "0.13.0" are the same version
REF="${ACTION_REF:-}"
# A version that the workflow names must be that version, or the step fails. Only a version that was not named
# (the action was called by a tag) may be built from the action's own sources instead: they are that tag's.
NAMED=0
if [[ -n "$VERSION" && "$VERSION" != "source" ]]; then NAMED=1; fi
if [[ -z "$VERSION" ]]; then
  # The action was called by a release tag: that release. Anything else (a branch, a commit): the sources.
  if [[ "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then VERSION="${REF#v}"; else VERSION="source"; fi
fi

# What the sources of the action's checkout are (it is an unpacked archive, not a git clone)
source_hash() {
  (cd "$ACTION_PATH" && find Package.swift Package.resolved Sources -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
}

if [[ "$MODE" == "key" ]]; then
  if [[ "$VERSION" == "source" ]]; then
    key="source-$(source_hash)-$(xcrun swift --version 2>/dev/null | shasum -a 256 | cut -c1-8)"
  else
    key="release-$VERSION"
  fi
  echo "key=$key" >>"$GITHUB_OUTPUT"
  echo "xcmutate: $VERSION (cache key $key)"
  exit 0
fi

BIN="$TOOL_DIR/bin"
mkdir -p "$BIN"

# The sources need Swift 6.3 or newer (Package.swift). Said before the build starts, with what the runner has: the
# error of the package manager names the tools version and not what to do about it.
require_swift() {
  local version major minor
  version="$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
  major="${version%%.*}"; minor="${version#*.}"
  if [[ -z "$version" ]]; then
    echo "::error::xcmutate: no Swift toolchain was found on this runner (xcrun swift --version). Building the tool from its sources needs Swift 6.3 or newer (checked with Xcode 26.6 and 27.2); name a release with the input \"version\" to download the binary instead."
    exit 2
  fi
  if (( major < 6 || (major == 6 && minor < 3) )); then
    echo "::error::xcmutate: this runner has Swift $version ($(xcodebuild -version 2>/dev/null | head -1)); building the tool from its sources needs Swift 6.3 or newer. Name a release with the input \"version\" (its binary is downloaded and needs no build), or select a newer Xcode before this step (sudo xcode-select -s /Applications/Xcode_<version>.app; installed: $(ls /Applications 2>/dev/null | grep -i '^xcode' | tr '\n' ' '))."
    exit 2
  fi
}

build_from_source() {
  require_swift
  echo "xcmutate: building from the sources of the action ($ACTION_PATH)"
  swift build -c release --product xcmutate --package-path "$ACTION_PATH" --scratch-path "$TOOL_DIR/build"
  cp "$TOOL_DIR/build/release/xcmutate" "$BIN/xcmutate"
}

download_release() {
  local name="xcmutate-$VERSION-macos-universal.tar.gz"
  local base="https://github.com/$ACTION_REPOSITORY/releases/download/v$VERSION"
  local temp
  temp="$(mktemp -d)"
  local auth=()
  # A private repository serves release assets only to an authenticated request
  if [[ -n "${GH_TOKEN:-}" ]]; then auth=(-H "Authorization: Bearer $GH_TOKEN"); fi
  echo "xcmutate: downloading $base/$name"
  curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} -o "$temp/$name" "$base/$name" || return 1
  curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} -o "$temp/$name.sha256" "$base/$name.sha256" || return 1
  (cd "$temp" && shasum -a 256 -c "$name.sha256") || { echo "xcmutate: the checksum of $name does not match" >&2; return 1; }
  tar -xzf "$temp/$name" -C "$temp"
  cp "$temp/xcmutate-$VERSION-macos-universal/xcmutate" "$BIN/xcmutate"
  rm -rf "$temp"
}

CACHED=""
if [[ -x "$BIN/xcmutate" ]]; then CACHED="$("$BIN/xcmutate" --version 2>/dev/null || true)"; fi
if [[ -n "$CACHED" && "$VERSION" != "source" && "$CACHED" != "$VERSION" ]]; then
  # A cache that holds another version than the one asked for is not used
  echo "xcmutate: the cached executable is version $CACHED, not $VERSION; installing again"
  mv "$BIN/xcmutate" "$BIN/xcmutate.other"
  CACHED=""
fi
if [[ -n "$CACHED" ]]; then
  echo "xcmutate: using the cached executable"
elif [[ "$VERSION" == "source" ]]; then
  build_from_source
elif ! download_release; then
  if [[ "$NAMED" == 1 ]]; then
    echo "::error::xcmutate $VERSION could not be downloaded from the releases of $ACTION_REPOSITORY. The input \"version\" names a release (with or without a leading v); leave it empty to use the version of the action's own ref, or set it to \"source\" to build the action's sources."
    exit 1
  fi
  echo "::notice::xcmutate $VERSION could not be downloaded as a release binary; building from the sources of the action's ref ($REF) instead."
  build_from_source
fi

echo "xcmutate $("$BIN/xcmutate" --version)"
echo "$BIN" >>"$GITHUB_PATH"
