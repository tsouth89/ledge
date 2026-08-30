#!/usr/bin/env bash
# Assert the PKGBUILD ships the whole shell tree.
#
# An earlier PKGBUILD installed only *.qml and qmldir, silently dropping
# Core/Markup.js, which every note imports. The source tree ran fine and the
# built package could not start. This checks the packaging rule rather than the
# built artifact, so it can run anywhere, without makepkg.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

if ! grep -q 'cp -r shell' PKGBUILD; then
  echo "FAIL: PKGBUILD no longer copies the shell tree wholesale."
  echo "      Installing a filtered subset is how Core/Markup.js went missing."
  fail=1
fi

if grep -qE "find shell .*-name '\*\.[a-z]+'" PKGBUILD; then
  echo "FAIL: PKGBUILD filters the shell tree by extension."
  fail=1
fi

# Every non-QML file the shell imports must be inside shell/, or it will not be
# packaged no matter how the copy is written.
while read -r ref; do
  [[ -f "shell/$ref" || -f "$ref" ]] && continue
  echo "FAIL: shell imports '$ref', which is not in the shell tree"
  fail=1
done < <(grep -rhoE '^import "[^"]+\.js"' shell | sed 's/^import "//; s/"$//' | sed 's|\.\./||')

[[ $fail -eq 0 ]] && echo "packaging covers the shell tree"
exit $fail
