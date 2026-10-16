#!/usr/bin/env bash
# Builds this repo's bundle (lib/build.mjs, always the public build) and fails
# if anything of the personal build's own mascot made it in: an upstream
# source of his (esbuild marks each bundled file with a `// path/to/file.ts`
# line), or code that draws or animates him (his drawing functions and
# helpers, outfits, the personal-only port modules), his colours, or his name,
# in the bundle or anywhere in the repo.
# Usage: tools/check-public.sh [out.js]   (default /tmp/robo-lib.public.js;
# the committed mod/payload/modules/robo/robo-lib.js is left alone)
# CHECK_ROOT=<dir>: check that checkout instead of this one.
#
# (His name is spelt in octal below, so this script passes its own check.)
set -euo pipefail
here="${CHECK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
out="${1:-/tmp/robo-lib.public.js}"
lo="$(printf '\155\157\143\150\151')"   # his name, lower case
Up="$(printf '\115\157\143\150\151')"   # and capitalised

node "$here/lib/build.mjs" "$out" >/dev/null
fail=0

# 1. Bundled source files: none under an upstream directory of his, none of
#    the personal-only port modules.
files="$(grep -E '^\s*// \S+\.(ts|js)$' "$out" | awk '{print $NF}' | sort -u)"
bad="$(printf '%s\n' "$files" | grep -E "(^|/)$lo/|lib/ambxst/personal-patch\.ts$|lib/personal-only\.ts$" || true)"
if [ -n "$bad" ]; then
  echo "check-public: his sources in the bundle:" >&2
  printf '  %s\n' $bad >&2
  fail=1
fi

# 2. His drawing and animation code, by name (comments stripped first).
names="draw$Up|${lo}Path|whiteFill|drawHandsBehind|drawEyeShape|drawOutfitBehind|drawOutfitFront|drawWardrobeIcon\(ctx, *size|makeHead|PUMPKIN_BODY|eyeFrames|bodyOutline|BASE_TOP: *RGB|MINI_INK"
code="$(sed -E 's#(^|[[:space:]])//.*$##' "$out")"
hits="$(printf '%s\n' "$code" | grep -nE "\b($names)\b" || true)"
if [ -n "$hits" ]; then
  echo "check-public: his drawing code in the bundle:" >&2
  printf '%s\n' "$hits" | head -20 >&2
  fail=1
fi

# 3. His own art constants (his body greys, ink, upload body gradient).
cols='"#EDEDEF"|"#C4C5CA"|"rgb\(251,251,252\)"|"rgb\(231,233,236\)"|"#1A1412"|rgb\(26,20,18\)|"#0E0F12"'
art="$(printf '%s\n' "$code" | grep -nE "$cols" || true)"
if [ -n "$art" ]; then
  echo "check-public: his colours in the bundle:" >&2
  printf '%s\n' "$art" | head -20 >&2
  fail=1
fi

# 4. Not even the name: the bundle never says it (comments included).
named="$(grep -niE "$lo" "$out" || true)"
if [ -n "$named" ]; then
  echo "check-public: his name in the bundle:" >&2
  printf '%s\n' "$named" | head -20 >&2
  fail=1
fi

# 5. The bundle must know it is public.
grep -q 'var PUBLIC = true' "$out" || { echo "check-public: PUBLIC is not true in $out" >&2; fail=1; }

# 6. The repo itself: the same names and colours in any source shipped, not
#    just in the bundle, no upstream sources of his or personal-only port
#    modules at all, and no file naming him.
srcs="$(cd "$here" && find lib mod -path lib/node_modules -prune -o -type f \( -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.qml' \) -print | sort)"
stray="$(cd "$here" && find . -path ./node_modules -prune -o -path ./.git -prune -o \( -path "*/$lo/*" -o -path ./lib/personal-only.ts -o -path ./lib/ambxst/personal-patch.ts -o -path ./core/src/legacy.rs \) -print)"
if [ -n "$stray" ]; then
  echo "check-public: his sources in the repo:" >&2
  printf '  %s\n' $stray >&2
  fail=1
fi
# (Comments stripped, block ones too. Upstream's `BASE_TOP: RGB` only means
# something in the bundle: Axenide's engine has its own. His colours are
# looked for in lib/ only: RoboIsland.qml compares the colours the personal
# build's greeting draws in, to retint them.)
snames="$(printf '%s' "$names" | sed 's/|BASE_TOP: \*RGB//')"
shits="$(cd "$here" && for f in $srcs; do
  pat="\b($snames)\b"
  case "$f" in lib/*) pat="$pat|$cols" ;; esac
  sed -E 's#(^|[[:space:]])//.*$##; s#^[[:space:]]*(/\*|\*).*$##' "$f" | grep -nE "$pat" | sed "s#^#$f:#"
done || true)"
if [ -n "$shits" ]; then
  echo "check-public: his drawing code or colours in the sources:" >&2
  printf '%s\n' "$shits" | head -20 >&2
  fail=1
fi
named="$(cd "$here" && { git ls-files 2>/dev/null || find . -type f -not -path './node_modules/*' -not -path './.git/*'; } | grep -iE "$lo" || true)"
named="$named$(cd "$here" && grep -rIil "$lo" --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=target . || true)"
if [ -n "$named" ]; then
  echo "check-public: his name in the repo:" >&2
  printf '  %s\n' $named >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-public: FAILED ($out)" >&2
  exit 1
fi
echo "check-public: OK ($out, $(printf '%s\n' "$files" | wc -l) source files)"
