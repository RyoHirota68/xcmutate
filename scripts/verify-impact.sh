#!/bin/bash
# Checks --write-impact-map and --select-tests impact on Fixtures/Impact, a package on macOS, in a temporary git
# repository (the runs need commits of their own):
#
#   1. a run of whole files writes the map (which suites ran which file);
#   2. a change of Price.swift: impact selects the suites that ran it, and gives the verdicts of --select-tests reach;
#   3. a new test file: its suite is added, the map does not know it;
#   4. a changed test helper: the whole selection runs, and the warning says why;
#   5. a map whose commit is not in the history: the whole selection runs.
#
#   scripts/verify-impact.sh
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="${XCMUTATE_BIN:-}"
if [ -z "$BIN" ]; then
  swift build --product xcmutate >/dev/null || { echo "swift build failed"; exit 1; }
  BIN="$REPO/.build/debug/xcmutate"
fi
OUT="$REPO/.build/impact"
rm -rf "$OUT"
mkdir -p "$OUT"
PROJECT="$OUT/Shop"
cp -R "$REPO/Fixtures/Impact" "$PROJECT"
rm -rf "$PROJECT/.build"
git_() { git -C "$PROJECT" -c user.name=check -c user.email=check@example.invalid "$@"; }
git_ init -q -b main && git_ add -A && git_ commit -q -m base
failures=0
check() {   # check <description> <command...>
  local what="$1"
  shift
  if "$@"; then echo "  ok: $what"; else echo "  FAILED: $what"; failures=$((failures + 1)); fi
}
run() {   # run <label> [options...]
  local label="$1"
  shift
  (cd "$PROJECT" && "$BIN" run --package . --scheme Shop --destination 'platform=macOS' --no-caffeinate --work-dir "$OUT/work" \
      --reporter json --json-output "$OUT/$label.json" "$@") >"$OUT/$label.log" 2>&1
}
json() { /usr/bin/python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print($2)" "$OUT/$1.json"; }

echo "== 1. the map of a run of whole files"
run nightly --select-tests reach --write-impact-map "$OUT/map.json"
check "the run passes and writes the map" test -s "$OUT/map.json"
# (ReceiptTests runs code of Cart.swift too, but no line of it with a mutant: a suite is in the map for a file when
# it evaluated a switch there)
check "the map: Price.swift was run by PriceTests and ReceiptTests, Cart.swift by CartTests" \
  /usr/bin/python3 -c "import json,sys; m=json.load(open(sys.argv[1])); f=m['files']; sys.exit(0 if f['Sources/Shop/Price.swift'] == ['ShopTests/PriceTests', 'ShopTests/ReceiptTests'] and f['Sources/Shop/Cart.swift'] == ['ShopTests/CartTests'] and len(m['suites']) == 3 else 1)" "$OUT/map.json"

echo "== 2. a change of Price.swift"
sed -i '' 's/total > 100 ? total - 10 : total/total >= 100 ? total - 10 : total/' "$PROJECT/Sources/Shop/Price.swift"
git_ commit -q -am "price"
run impact --since HEAD~1 --select-tests impact --impact-map "$OUT/map.json"
check "the suites that ran Price.swift are selected (2 of 3), and the warning says that the results hold among them" \
  test "$(json impact "r['testSelection']['mode'], r['testSelection']['onlyTesting'], any(w['kind'] == 'impactSelection' for w in r['warnings'])")" = "impact ['ShopTests/PriceTests', 'ShopTests/ReceiptTests'] True"
run reach --since HEAD~1 --select-tests reach
check "the verdicts are those of --select-tests reach over all tests" \
  test "$(json impact "sorted((x['mutant']['key'], x['status']) for x in r['results'])")" = "$(json reach "sorted((x['mutant']['key'], x['status']) for x in r['results'])")"

echo "== 3. a new test file"
cat >"$PROJECT/Tests/ShopTests/BulkTests.swift" <<'EOF'
import XCTest
@testable import Shop

final class BulkTests: XCTestCase {
    func testBulk() { XCTAssertEqual(Price.discounted(100), 90) }
}
EOF
git_ add -A && git_ commit -q -m "bulk"
run newtest --since HEAD~2 --select-tests impact --impact-map "$OUT/map.json"
check "the new suite is added to the suites of Price.swift" \
  test "$(json newtest "r['testSelection']['onlyTesting'], r['testSelection']['impact']['newSuites']")" = "['ShopTests/BulkTests', 'ShopTests/PriceTests', 'ShopTests/ReceiptTests'] ['BulkTests']"

echo "== 4. a changed test helper"
echo "func moreItems() -> [Int] { [4] }" >>"$PROJECT/Tests/ShopTests/Helpers.swift"
git_ commit -q -am "helper"
run helper --since HEAD~3 --select-tests impact --impact-map "$OUT/map.json"
check "the whole selection runs, and the warning names the helper" \
  test "$(json helper "r['testSelection']['onlyTesting'], any(w['kind'] == 'impactFallback' and 'Helpers.swift' in w['message'] for w in r['warnings'])")" = "[] True"

echo "== 5. a map of a commit that is not in this history"
/usr/bin/python3 -c "import json,sys; m=json.load(open(sys.argv[1])); m['commit']='0'*40; json.dump(m, open(sys.argv[2],'w'))" "$OUT/map.json" "$OUT/foreign.json"
run foreign --since HEAD~3 --select-tests impact --impact-map "$OUT/foreign.json"
check "the whole selection runs, and the warning says why" \
  test "$(json foreign "any(w['kind'] == 'impactFallback' and 'not an ancestor' in w['message'] for w in r['warnings'])")" = "True"

"$BIN" clean --work-dir "$OUT/work" >/dev/null 2>&1 || true
if [ "$failures" -gt 0 ]; then echo "$failures impact check(s) failed (logs: $OUT)"; exit 1; fi
echo "all impact checks passed"
