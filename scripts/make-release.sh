#!/bin/bash
# Builds the release archive of xcmutate on this Mac and checks it. Nothing is uploaded and no tag is made.
#
#   scripts/make-release.sh [--skip-run] [--output <directory>]
#
# Output (default .build/release-artifacts/):
#   xcmutate-<version>-macos-universal.tar.gz          the executable for arm64 and x86_64, LICENSE, THIRD_PARTY_NOTICES.md
#   xcmutate-<version>-macos-universal.tar.gz.sha256   `shasum -a 256` line of the archive
#   xcmutate.rb                                        the Homebrew formula for it (for the account RyoHirota68 unless OWNER is set)
#
# Checks on the unpacked archive: both architectures are there; `--version` prints the version of the sources; `list`
# and (unless --skip-run) a `run` of a small package on macOS work from a directory outside the repository; the
# executable does not hold the path of this checkout or the user name; and the message when Xcode is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
OUT="$REPO/.build/release-artifacts"
SKIP_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-run) SKIP_RUN=1; shift ;;
    --output) OUT="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2 ;;
    *) sed -n '2,13p' "$0" >&2; exit 64 ;;
  esac
done

VERSION="$(sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/MutatorRunner/ToolInfo.swift)"
[[ -n "$VERSION" ]] || { echo "cannot read the version from ToolInfo.swift" >&2; exit 1; }
NAME="xcmutate-$VERSION-macos-universal"
SCRATCH="$REPO/.build/release-universal"
echo "== building xcmutate $VERSION for arm64 and x86_64"
# No path of this checkout goes into a release build's executable (checked below), so no prefix map is needed
swift build -c release --product xcmutate --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"
BUILT="$(swift build -c release --product xcmutate --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)/xcmutate"
[[ -x "$BUILT" ]] || { echo "no executable at $BUILT" >&2; exit 1; }

STAGE="${OUT:?}/${NAME:?}"
if [[ -d "$STAGE" ]]; then find "$STAGE" -mindepth 1 -delete; fi
mkdir -p "$STAGE"
cp "$BUILT" "$STAGE/xcmutate"
strip -x "$STAGE/xcmutate"
# strip invalidates the ad-hoc signature that the linker made; arm64 does not run unsigned code
codesign --force --sign - "$STAGE/xcmutate"
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
# The entries carry no user name, user id or extended attribute of whoever made the archive
(cd "$OUT" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel --no-xattrs --no-mac-metadata -czf "$NAME.tar.gz" "$NAME" \
  && shasum -a 256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256")
SHA="$(cut -d' ' -f1 "$OUT/$NAME.tar.gz.sha256")"
echo "archive: $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1 | tr -d ' '))"
echo "sha256:  $SHA"
scripts/make-formula.sh "$VERSION" "$SHA" "${OWNER:-RyoHirota68}" "$OUT/xcmutate.rb" >/dev/null

echo "== checking the archive"
failures=0
check() { if "$@"; then echo "  ok: $CHECK"; else echo "  FAILED: $CHECK"; failures=$((failures + 1)); fi; }
# A directory of its own under the output directory; it is emptied here and left for inspection
TRY="${OUT:?}/check"
if [[ -d "$TRY" ]]; then
  find "$TRY" -mindepth 1 -delete
fi
mkdir -p "$TRY"
tar -xzf "$OUT/$NAME.tar.gz" -C "$TRY"
TOOL="$TRY/$NAME/xcmutate"

CHECK="the executable holds arm64 and x86_64"
check bash -c "lipo -archs '$TOOL' | tr ' ' '\n' | sort | tr '\n' ' ' | grep -q 'arm64 x86_64'"
CHECK="--version prints $VERSION"
check bash -c "[ \"\$('$TOOL' --version)\" = '$VERSION' ]"
CHECK="the x86_64 slice runs (Rosetta; skipped when it is not installed)"
if arch -x86_64 /usr/bin/true 2>/dev/null; then check bash -c "[ \"\$(arch -x86_64 '$TOOL' --version)\" = '$VERSION' ]"; else echo "  skipped: $CHECK"; fi
CHECK="the licence texts are in the archive"
check test -s "$TRY/$NAME/LICENSE" -a -s "$TRY/$NAME/THIRD_PARTY_NOTICES.md"
# Every byte, not `strings`: that tool leaves out the symbol string table, where the paths of an unstripped build are
CHECK="the executable does not hold the path of this checkout, the home directory or the user name (all bytes)"
check bash -c "! LC_ALL=C grep -a -c -F -e '$REPO' -e '$HOME' -e '/Users/$(id -un)' '$TOOL' | grep -v '^0\$'"
CHECK="the executable is stripped of local symbols (no symbol with a source file name)"
check bash -c "! nm -a '$TOOL' 2>/dev/null | grep -E ' (SO|OSO) ' | head -3 | grep ."
# The user's home path, not the bare user name: on GitHub's runners the user is `runner`, a word that the
# executable holds in identifiers such as `runnerError`. The owner fields are checked by the first half
CHECK="the entries of the archive belong to root/wheel and the archive does not hold the home path of the user or extended attributes"
check bash -c "! tar -tvzf '$OUT/$NAME.tar.gz' | awk '{print \$3, \$4}' | grep -v '^root wheel\$' | grep . && ! gunzip -c '$OUT/$NAME.tar.gz' | LC_ALL=C grep -a -c -F -e '/Users/$(id -un)' -e 'SCHILY.xattr' -e 'LIBARCHIVE.xattr' | grep -v '^0\$'"
CHECK="the executable links only against system libraries"
check bash -c "! otool -L '$TOOL' | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/Library/' -e ':\$' | grep ."

# A small package outside this repository (inside it, the work copy would be a copy of this repository)
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/xcmutate-release-check.XXXXXX")"
PACKAGE="$OUTSIDE/Sample"
mkdir -p "$PACKAGE/Sources/Sample" "$PACKAGE/Tests/SampleTests"
cat >"$PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Sample", products: [.library(name: "Sample", targets: ["Sample"])],
                      targets: [.target(name: "Sample"), .testTarget(name: "SampleTests", dependencies: ["Sample"])])
SWIFT
cat >"$PACKAGE/Sources/Sample/Age.swift" <<'SWIFT'
public func isAdult(_ age: Int) -> Bool { age >= 18 }
public func isChild(_ age: Int) -> Bool { age < 13 }
SWIFT
cat >"$PACKAGE/Tests/SampleTests/AgeTests.swift" <<'SWIFT'
import XCTest
@testable import Sample
final class AgeTests: XCTestCase {
    func testAdult() { XCTAssertTrue(isAdult(30)); XCTAssertFalse(isAdult(3)) }
    func testChild() { XCTAssertTrue(isChild(12)); XCTAssertFalse(isChild(13)) }
}
SWIFT
CHECK="list shows the mutants of a file (no Xcode project needed)"
check bash -c "cd '$PACKAGE' && '$TOOL' list --root . Sources/Sample/Age.swift | grep -q boundary"
if [[ "$SKIP_RUN" == 0 ]]; then
  CHECK="run works on a package on macOS (the tests do not try 18: one mutant survives, one is killed)"
  check bash -c "cd '$PACKAGE' && '$TOOL' run --root . --package . --scheme Sample --destination 'platform=macOS' --no-caffeinate --work-dir '$OUTSIDE/work' --reporter json --json-output '$TRY/report.json' Sources/Sample/Age.swift >'$TRY/run.log' 2>&1; grep -q '\"Survived\"' '$TRY/report.json' && grep -q '\"Killed\"' '$TRY/report.json'"
  [[ -f "$TRY/run.log" ]] && tail -3 "$TRY/run.log" | sed 's/^/    /'
fi
CHECK="without Xcode (DEVELOPER_DIR points nowhere) run stops with a message that names Xcode"
check bash -c "cd '$PACKAGE' && DEVELOPER_DIR=/nonexistent '$TOOL' run --root . --package . --scheme Sample --destination 'platform=macOS' --no-caffeinate --work-dir '$OUTSIDE/work2' Sources/Sample/Age.swift >'$TRY/noxcode.log' 2>&1; grep -qi 'xcode' '$TRY/noxcode.log'"
[[ -f "$TRY/noxcode.log" ]] && tail -2 "$TRY/noxcode.log" | sed 's/^/    /'

for work in "$OUTSIDE/work" "$OUTSIDE/work2"; do [[ -d "$work" ]] && "$TOOL" clean --work-dir "$work" >/dev/null 2>&1; done
find "${OUTSIDE:?}" -mindepth 1 -delete 2>/dev/null; rmdir "$OUTSIDE" 2>/dev/null || true

if [[ "$failures" -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
echo "formula: $OUT/xcmutate.rb"
