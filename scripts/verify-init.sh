#!/bin/bash
# Checks `xcmutate init` on Fixtures/LogicKit (a package on macOS) in a temporary git repository that has the JSON
# config file of an earlier version: --dry-run writes nothing; init without --force writes nothing and keeps the JSON
# file; with --force it writes xcmutate.yml (the JSON file's setting carried over, the reasons as comments, no weaker
# option or gate) and removes the JSON file; a run with --profile nightly gives the verdicts the fixture expects
# (Killed 18, Survived 5); a second init does not replace the file without --force.
#
#   scripts/verify-init.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="${XCMUTATE_BIN:-}"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$REPO/.build/debug/xcmutate"
fi
OUT="$REPO/.build/init"
rm -rf "$OUT"
mkdir -p "$OUT"
PROJECT="$OUT/LogicKit"
cp -R "$REPO/Fixtures/LogicKit" "$PROJECT"
rm -rf "$PROJECT/.build"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid add -A
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid commit -q -m base
failures=0
check() {
  local what="$1"
  shift
  if "$@"; then echo "  ok: $what"; else echo "  FAILED: $what"; failures=$((failures + 1)); fi
}
CONFIG="$PROJECT/xcmutate.yml"
LEGACY="$PROJECT/xcmutate.config.json"
# YAML to JSON for the checks (Ruby's YAML; the file quotes every string, so YAML 1.1 reads it the same way)
yaml_json() { /usr/bin/ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1"; }
export -f yaml_json
# The config file of an earlier version, with a setting of its own
printf '{\n  "exclude": ["Generated/**"],\n  "_note": "kept from 0.14"\n}\n' >"$LEGACY"
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid add -A
git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid commit -q -m legacy

echo "== init --dry-run"
(cd "$PROJECT" && "$BIN" init --yes --dry-run) >"$OUT/dry.out" 2>"$OUT/dry.err"
check "prints a YAML file and writes nothing" bash -c "grep -q '^profiles:' '$OUT/dry.out' && [ ! -e '$CONFIG' ] && [ -e '$LEGACY' ]"

echo "== init without --force, with the JSON file of an earlier version"
(cd "$PROJECT" && "$BIN" init --yes) >"$OUT/legacy.out" 2>"$OUT/legacy.err"
status=$?
check "writes nothing, keeps the JSON file, says how to move it (exit code 1)" bash -c "[ $status -eq 1 ] && [ ! -e '$CONFIG' ] && [ -e '$LEGACY' ] && grep -q 'Write it with --force' '$OUT/legacy.err'"

echo "== init --force"
(cd "$PROJECT" && "$BIN" init --yes --force) >"$OUT/init.out" 2>"$OUT/init.err"
check "writes xcmutate.yml with run, pr and nightly and the setting of the JSON file, and removes the JSON file" bash -c "[ ! -e '$LEGACY' ] && yaml_json '$CONFIG' | /usr/bin/python3 -c \"import json,sys; c=json.load(sys.stdin); sys.exit(0 if c['run']['package'] == '.' and c['run']['scheme'] == 'LogicKit' and {'pr', 'nightly'} <= set(c['profiles']) and c['exclude'] == ['Generated/**'] and not any(k.startswith('_') for k in c) else 1)\""
check "no option that makes verdicts weaker, and no gate" bash -c "yaml_json '$CONFIG' | /usr/bin/python3 -c \"import json,sys; c=json.load(sys.stdin); parts=[c['run']]+list(c['profiles'].values()); sys.exit(0 if all(k not in p for p in parts for k in ('failUnder','failOnSurvived','baselineReport','stopWhenGateDecided')) and all(p.get('confirmKills') != 'none' for p in parts) else 1)\""
check "the file starts with where its keys are documented, and the reasons are comments" bash -c "head -1 '$CONFIG' | grep -q 'docs/usage.md' && grep -q '^ *# ' '$CONFIG' && ! grep -q '_why' '$CONFIG'"
check "the reasons are printed" grep -q "nightly.sharedProcess" "$OUT/init.err"
echo "== run --profile nightly"
(cd "$PROJECT" && "$BIN" run --profile nightly --no-caffeinate --work-dir "$OUT/work" --reporter json --json-output "$OUT/nightly.json") >"$OUT/nightly.log" 2>&1
check "the verdicts the fixture expects: Killed 18, Survived 5; the settings came from the profile" \
  test "$(/usr/bin/python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(r['counts'].get('Killed'), r['counts'].get('Survived'), r['settings']['profile'])" "$OUT/nightly.json")" = "18 5 nightly"
MAP="$(yaml_json "$CONFIG" | /usr/bin/python3 -c "import json,os,sys; p=json.load(sys.stdin)['profiles']['nightly']['writeImpactMap']; p=os.path.expanduser(p); print(p if os.path.isabs(p) else os.path.join(sys.argv[1], p))" "$PROJECT")"
check "the impact map of the nightly profile was written, outside what git tracks" bash -c "test -s '$MAP' && { case '$MAP' in '$PROJECT'/*) git -C '$PROJECT' check-ignore -q '$MAP' ;; *) true ;; esac; }"
case "$MAP" in "$HOME"/Library/Caches/*) rm -f "$MAP" ;; esac

echo "== init again"
(cd "$PROJECT" && "$BIN" init --yes) >"$OUT/again.out" 2>"$OUT/again.err"
status=$?
check "an existing file with run options is not replaced (exit code 1, the proposal is shown)" bash -c "[ $status -eq 1 ] && grep -q 'nothing was written' '$OUT/again.err'"

"$BIN" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
if [ "$failures" -gt 0 ]; then echo "$failures init check(s) failed (logs: $OUT)"; exit 1; fi
echo "all init checks passed"
