#!/bin/bash
# Measures every operator on public Swift packages: how many mutants it makes, how many of them are killed,
# survive, are not reached, do not compile or time out.
#
#   scripts/operator-campaign.sh              # fetch every package, run, summarize
#   scripts/operator-campaign.sh Files Version  # only these packages
#   CAMPAIGN_ONLY=fetch scripts/operator-campaign.sh   # fetch only (and list the mutants per package)
#   CAMPAIGN_ONLY=summary scripts/operator-campaign.sh # summarize the reports that exist
#   CAMPAIGN_EXTRA_ARGS="--workers 2" scripts/operator-campaign.sh Expression   # extra arguments for every run
#     (`--workers 2` halves the time of packages in which many mutants crash, each of which needs a run of its
#     own; do not use it for packages whose tests share files, such as Files. `--resume` continues a run that
#     was interrupted.)
#
# The packages are fetched at fixed commits into .build/campaign/src (nothing of them is committed to this
# repository); where each comes from and under which licence is in the table below and is written to
# .build/campaign/sources.txt with the first line of its licence file. Everything runs on macOS
# (`--destination 'platform=macOS'`): no simulator is used. Operators that are off by default are switched on
# for the measurement. Reports go to .build/campaign/reports, the summary to .build/campaign/summary.md and the
# list of survivors (with source context, for reading and classifying) to .build/campaign/survivors.md.
#
# Also included: the two packages among Muter's sample projects that scripts/verify-muter-fixtures.sh runs
# (BonMot and FFCParserCombinator), taken from the copy of Muter that that script fetches.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CAMPAIGN="$ROOT/.build/campaign"
WORK="${CAMPAIGN_WORK:-$HOME/Library/Caches/xcmutate/campaign.noindex}"
mkdir -p "$CAMPAIGN/src" "$CAMPAIGN/reports" "$WORK"

# name | repository | tag | commit | licence | scheme | source directories (their .swift files are mutated) | prepare command (run in the work copy) | extra run arguments (no spaces inside one argument)
#
# What the prepare commands and extra arguments are for:
# - Packages that also carry an .xcodeproj: it is removed in the work copy, so that xcodebuild builds the package.
# - SwiftyJSON: three test classes read Tests/Tes/Tests.json through the bundle of the test class, which finds it
#   only in the project's own Xcode targets. In the work copy they are pointed at the file next to the sources.
#   PerformanceTests (XCTest `measure` blocks, 4 s per run of the tests) is left out. Many of its mutants recurse
#   without end (every accessor goes through the same few properties), so the constant part of the timeout is
#   12 s instead of 30 s; a slow crash can then be recorded as Timeout, which counts as detected either way.
# - Expression: MetadataTests compares version numbers in the podspec, the changelog and the .xcodeproj; left out.
#
# Tried and left out: apple/swift-algorithms 1.2.1 (nearly everything is @inlinable, where the tool does not mutate:
# 11 mutants in 27 files) and drmohundro/SWXMLHash 8.1.0 (its tests are written against the swift-testing package
# rather than the toolchain's Testing module; xcodebuild built them with -skipMacroValidation and then ran none).
PACKAGES='
SwiftyJSON|https://github.com/SwiftyJSON/SwiftyJSON.git|5.0.2|af76cf3ef710b6ca5f8c05f3a31307d44a3c5828|MIT|SwiftyJSON|Source/SwiftyJSON|rm -rf SwiftyJSON.xcodeproj SwiftyJSON.xcworkspace Example && sed -i "" -E "s@Bundle\(for: [A-Za-z]+\.self\)\.path\(forResource: \"Tests\", ofType: \"json\"\)@Optional(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(\"Tes/Tests.json\").path)@" Tests/SwiftJSONTests/BaseTests.swift Tests/SwiftJSONTests/PerformanceTests.swift Tests/SwiftJSONTests/SequenceTypeTests.swift|--skip-testing SwiftJSONTests/PerformanceTests --timeout-constant 12
HTTPTypes|https://github.com/apple/swift-http-types.git|1.4.0|a0a57e949a8903563aba4615869310c0ebf14c03|Apache-2.0|swift-http-types-Package|Sources/HTTPTypes||
Expression|https://github.com/nicklockwood/Expression.git|0.13.9|95ffe4c352e456cede933d9910d25b9c84039d1b|MIT|Expression|Sources|rm -rf Expression.xcodeproj Examples Benchmarks|--skip-testing ExpressionTests/MetadataTests
Files|https://github.com/JohnSundell/Files.git|4.3.0|e85f2b4a8dfa0f242889f45236f3867d16e40480|MIT|Files|Sources|rm -rf Files.xcodeproj|
Version|https://github.com/mxcl/Version.git|2.2.0|67ce582bb9de70e1eb2ee41fd71aad3b5f86d97b|Apache-2.0|Version|Sources||
'
# Every operator that is, or was at some point, off by default: the measurement covers all operators
OFF_BY_DEFAULT="arithmetic compound-assignment guard-removal nil-coalescing-default return-case implicit-return-value closure-statement-removal switch-case-removal try-optional-nil condition-removal"

swift build --product xcmutate >/dev/null || exit 1
BIN="$ROOT/.build/debug/xcmutate"
ENABLE=()
for op in $OFF_BY_DEFAULT; do ENABLE+=(--enable-operator "$op"); done
# shellcheck disable=SC2206
ENABLE+=(${CAMPAIGN_EXTRA_ARGS:-})
ONLY="${CAMPAIGN_ONLY:-}"
SELECTED=("$@")
selected() { [[ ${#SELECTED[@]} -eq 0 ]] && return 0; for s in "${SELECTED[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

fetch() { # name url tag commit
  local dir="$CAMPAIGN/src/$1"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$2"
  fi
  if [[ -z "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" ]]; then
    git -C "$dir" fetch -q --depth 1 origin "refs/tags/$3" && git -C "$dir" checkout -q FETCH_HEAD || return 1
  fi
  local head; head="$(git -C "$dir" rev-parse HEAD)"
  if [[ -n "$4" && "$head" != "$4" ]]; then
    echo "$1: tag $3 is at $head, expected $4" >&2
    return 1
  fi
  local licence; licence="$(ls "$dir" | grep -iE '^(LICENSE|LICENCE|UNLICENSE)' | head -1)"
  echo "$1 | $2 | $3 | $head | ${licence:-no licence file}: $(head -1 "$dir/$licence" 2>/dev/null | cut -c1-80)"
}

run_package() { # name directory scheme directories prepare extra-arguments
  local name="$1" dir="$2" scheme="$3" files="$4" prepare="$5"
  local extra=()
  [[ -n "$prepare" ]] && extra=(--prepare "$prepare")
  # shellcheck disable=SC2206
  [[ -n "${6:-}" ]] && extra+=($6)
  local start; start=$(date +%s)
  # shellcheck disable=SC2086
  local list; list=$(cd "$dir" && find $files -name '*.swift' -not -name 'Package*.swift' | sort)
  if [[ "$ONLY" == "fetch" ]]; then
    # shellcheck disable=SC2086
    (cd "$dir" && "$BIN" list --root . "${ENABLE[@]}" $list 2>/dev/null | tail -1 | sed "s/^/$name: /")
    return
  fi
  # shellcheck disable=SC2086
  (cd "$dir" && "$BIN" run --root . --package . --scheme "$scheme" --destination 'platform=macOS' \
      --work-dir "$WORK/$name" --shared-process --max-rebuilds 12 "${ENABLE[@]}" \
      --reporter json --json-output "$CAMPAIGN/reports/$name.json" ${extra[@]+"${extra[@]}"} $list) > "$CAMPAIGN/reports/$name.log" 2>&1
  echo "$name: exit $? in $(( $(date +%s) - start ))s"
}

: > "$CAMPAIGN/sources.txt.new"
if [[ "$ONLY" != "summary" ]]; then
  while IFS='|' read -r name url tag commit licence scheme files prepare arguments; do
    [[ -z "$name" ]] && continue
    selected "$name" || continue
    fetch "$name" "$url" "$tag" "$commit" >> "$CAMPAIGN/sources.txt.new" || { echo "$name: fetch failed" >&2; continue; }
    run_package "$name" "$CAMPAIGN/src/$name" "$scheme" "$files" "$prepare" "$arguments"
  done <<< "$PACKAGES"
  [[ ${#SELECTED[@]} -eq 0 ]] && mv "$CAMPAIGN/sources.txt.new" "$CAMPAIGN/sources.txt"

  # Muter's sample packages (fetched by scripts/verify-muter-fixtures.sh; MIT License)
  MUTER="$ROOT/.build/external/muter/Repositories"
  if [[ -d "$MUTER/BonMot" ]] && selected BonMot; then
    BONMOT_FILES=$(cd "$MUTER/BonMot" && find Sources -name '*.swift' | grep -vE '/(Composable|Image\+Tinting|StringStyle)\.swift$' | sort | tr '\n' ' ')
    if [[ "$ONLY" != "fetch" ]]; then
      start=$(date +%s)
      # shellcheck disable=SC2086
      (cd "$MUTER/BonMot" && "$BIN" run --root . --package . --scheme BonMot --destination 'platform=macOS' --prepare 'mv BonMot.xcodeproj BonMot.xcodeproj.disabled' \
          --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0 --work-dir "$WORK/BonMot" --shared-process --max-rebuilds 12 "${ENABLE[@]}" \
          --reporter json --json-output "$CAMPAIGN/reports/BonMot.json" $BONMOT_FILES) > "$CAMPAIGN/reports/BonMot.log" 2>&1
      echo "BonMot: exit $? in $(( $(date +%s) - start ))s"
    fi
  fi
  if [[ -d "$MUTER/FFCParserCombinator" ]] && selected FFCParserCombinator && [[ "$ONLY" != "fetch" ]]; then
    start=$(date +%s)
    (cd "$MUTER/FFCParserCombinator" && "$BIN" run --root . --project FFCParserCombinator.xcodeproj --scheme FFCParserCombinator-Package --destination 'platform=macOS' \
        --build-arg=SWIFT_VERSION=5.0 --build-arg=MACOSX_DEPLOYMENT_TARGET=13.0 --work-dir "$WORK/FFCParserCombinator" --shared-process --max-rebuilds 12 "${ENABLE[@]}" \
        --reporter json --json-output "$CAMPAIGN/reports/FFCParserCombinator.json") > "$CAMPAIGN/reports/FFCParserCombinator.log" 2>&1
    echo "FFCParserCombinator: exit $? in $(( $(date +%s) - start ))s"
  fi
fi
rm -f "$CAMPAIGN/sources.txt.new"

[[ "$ONLY" == "fetch" ]] && exit 0
python3 scripts/operator-campaign.py "$CAMPAIGN" > "$CAMPAIGN/summary.md" && echo "summary: $CAMPAIGN/summary.md, survivors: $CAMPAIGN/survivors.md"
