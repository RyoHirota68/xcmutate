#!/bin/bash
# Writes the Homebrew formula of a release from packaging/homebrew/xcmutate.rb.template.
#
#   scripts/make-formula.sh <version> <sha256 of the release archive> <owner> [output file]
#
# <owner> is the GitHub account that holds the releases. Without an output file the formula goes to stdout.
set -euo pipefail
if [[ $# -lt 3 ]]; then
  sed -n '2,6p' "$0" >&2
  exit 64
fi
VERSION="$1"
SHA="$2"
OWNER="$3"
OUT="${4:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3, got $VERSION" >&2; exit 64; }
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256 must be 64 hexadecimal digits" >&2; exit 64; }
TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/xcmutate.rb.template"
formula="$(sed -e "s/@@VERSION@@/$VERSION/g" -e "s/@@SHA256@@/$SHA/g" -e "s/@@OWNER@@/$OWNER/g" "$TEMPLATE")"
if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  printf '%s\n' "$formula" >"$OUT"
  echo "formula: $OUT"
else
  printf '%s\n' "$formula"
fi
