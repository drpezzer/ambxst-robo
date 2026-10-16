#!/usr/bin/env bash
# End-to-end test of the mod's core installer (mod/payload/modules/robo/core/
# robo-core-install.sh) in a sandbox: temp HOME and XDG dirs, a local HTTP
# server with a release tarball + SHA256SUMS packed from core/target/release
# (as .github/workflows/release.yml packs them), systemctl stubbed on PATH.
# Nothing touches the real systemd user session or ~/.local/bin.
#
#   tools/test-core-install.sh            (build core first: cd core && cargo build --release)
#   tools/test-core-install.sh --source   also the cargo fallback (builds the core again, slow)
# shellcheck disable=SC2016,SC2034,SC2088 # the expect conditions are eval'd later
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/mod/payload/modules/robo/core/robo-core-install.sh"
rel="$here/core/target/release"
want="$(sed -n 's/^version=//p' "$here/mod/payload/modules/robo/core/RELEASE")"
arch="$(uname -m)"
source_too=0; [[ ${1:-} == --source ]] && source_too=1

T="$(mktemp -d)"
server=""
cleanup() { [[ -n $server ]] && kill "$server" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
pass=0; failn=0
ok() { echo "  ok   $*"; pass=$((pass + 1)); }
ko() { echo "  FAIL $*"; failn=$((failn + 1)); }
expect() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

[[ -x $rel/ambxst-robo && "$("$rel/ambxst-robo" --version)" == "ambxst-robo $want" ]] \
  || { echo "build the core $want first (cd core && cargo build --release)"; exit 1; }

# The mod as installed: the script and a public RELEASE.
mkdir -p "$T/mod"
cp "$script" "$T/mod/"
printf 'version=%s\nbuild=public\n' "$want" >"$T/mod/RELEASE"

# The release, packed like the workflow does.
pack() {
  local d="$T/pack/ambxst-robo-$want-$arch"
  rm -rf "$T/pack"; mkdir -p "$d" "$T/www/v$want"
  cp "$rel/ambxst-robo" "$rel/ambxst-robo-hook" "$d/"
  tar -C "$T/pack" -czf "$T/www/v$want/ambxst-robo-$want-$arch.tar.gz" "ambxst-robo-$want-$arch"
  (cd "$T/www/v$want" && sha256sum ambxst-robo-*.tar.gz >SHA256SUMS)
}
pack
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/" >/dev/null && break; sleep 0.1; done

# systemctl stub: logs its calls; is-active / MainPID from files.
mkdir -p "$T/stub"
cat >"$T/stub/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/systemctl.log"
case "$*" in
  *is-active*) s="$(cat "$STUB_DIR/active" 2>/dev/null || echo inactive)"; echo "$s"; [[ $s == active ]] ;;
  *MainPID*) cat "$STUB_DIR/mainpid" 2>/dev/null || echo 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/stub/systemctl"

sandbox() {  # a fresh HOME; run the installer with args
  rm -rf "${T:?}/home" "${T:?}/run"; mkdir -p "$T/home" "$T/run"; chmod 700 "$T/run"
  rm -f "$T/stub/"{systemctl.log,active,mainpid}
}
run() {
  env -i PATH="$T/stub:/usr/bin:/bin" HOME="$T/home" STUB_DIR="$T/stub" \
    XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" \
    XDG_CACHE_HOME="$T/home/.cache" AMBXST_ROBO_RELEASE_BASE="http://127.0.0.1:$port" \
    AMBXST_ROBO_SOURCE_URL="http://127.0.0.1:$port/src.tar.gz" "${EXTRA_ENV[@]}" \
    bash "$T/mod/robo-core-install.sh" "$@"
}
EXTRA_ENV=()
st() { sed -n "s/^$1=//p" "$T/run/ambxst-robo-install.status" 2>/dev/null; }
unitf="$T/home/.config/systemd/user/ambxst-robo.service"
binf="$T/home/.local/bin"

echo "1. fresh install"
sandbox
expect "check says missing" '[[ "$(run check)" == "state=missing installed=none want=$want active=inactive" ]]'
run install --run r1; code=$?
expect "exit 0" '[[ $code == 0 ]]'
expect "status done, run id" '[[ $(st phase) == done && $(st run) == r1 ]]'
expect "daemon installed" '[[ "$("$binf/ambxst-robo" --version)" == "ambxst-robo $want" ]]'
expect "relay installed" '[[ -x $binf/ambxst-robo-hook ]]'
expect "unit written, relay auto-install on" 'grep -q "^Environment=AMBXST_ROBO_INSTALL_RELAY=1$" "$unitf" && grep -q "^ExecStart=%h/.local/bin/ambxst-robo$" "$unitf"'
expect "daemon-reload, enable, start" 'grep -qx -- "--user daemon-reload" "$T/stub/systemctl.log" && grep -qx -- "--user enable ambxst-robo.service" "$T/stub/systemctl.log" && grep -qx -- "--user start ambxst-robo.service" "$T/stub/systemctl.log"'
expect "log written" '[[ -s $T/home/.local/state/ambxst-robo/core-install.log ]]'
expect "check says ok" '[[ "$(run check)" == state=ok* ]]'

echo "2. again: nothing to download, a stopped service is started"
: >"$T/stub/systemctl.log"
mv "$T/www/v$want" "$T/www/gone"
run install --run r2; code=$?
mv "$T/www/gone" "$T/www/v$want"
expect "exit 0 without the release" '[[ $code == 0 && $(st phase) == done ]]'
expect "no daemon-reload (unit unchanged)" '! grep -q daemon-reload "$T/stub/systemctl.log"'
expect "started" 'grep -qx -- "--user start ambxst-robo.service" "$T/stub/systemctl.log"'

echo "3. update over an older daemon that is running a chat turn"
printf '#!/bin/sh\necho "ambxst-robo 0.9.0"\n' >"$binf/ambxst-robo"
sed -i 's/^Environment=.*/#Environment=AMBXST_ROBO_INSTALL_RELAY=1/' "$unitf"
expect "check says outdated" '[[ "$(run check)" == "state=outdated installed=0.9.0"* ]]'
bash -c 'sleep 30 & wait' & daemon=$!
sleep 0.3
echo active >"$T/stub/active"; echo "$daemon" >"$T/stub/mainpid"
: >"$T/stub/systemctl.log"
EXTRA_ENV=(AMBXST_ROBO_WAIT_MAX=4)
run install --run r3 & inst=$!
saw_wait=0
for _ in $(seq 40); do [[ $(st phase) == waiting ]] && { saw_wait=1; break; }; sleep 0.2; done
expect "waits while the daemon has a child (a chat turn)" '[[ $saw_wait == 1 ]]'
expect "no restart while waiting" '! grep -q restart "$T/stub/systemctl.log"'
pkill -P "$daemon" sleep 2>/dev/null
wait "$inst"; code=$?
kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null
EXTRA_ENV=()
expect "then restarts and is done" '[[ $code == 0 && $(st phase) == done ]] && grep -qx -- "--user restart ambxst-robo.service" "$T/stub/systemctl.log"'
expect "updated" '[[ "$("$binf/ambxst-robo" --version)" == "ambxst-robo $want" ]]'
expect "unit rewritten" 'grep -q "^Environment=AMBXST_ROBO_INSTALL_RELAY=1$" "$unitf"'

echo "4. bad checksum"
sandbox
cp "$T/www/v$want/SHA256SUMS" "$T/sums.good"
sed -i -E 's/^[0-9a-f]{64}/'"$(printf '0%.0s' {1..64})"'/' "$T/www/v$want/SHA256SUMS"
run install --run r4; code=$?
cp "$T/sums.good" "$T/www/v$want/SHA256SUMS"
expect "refused (exit 1, error=checksum)" '[[ $code == 1 && $(st phase) == error && $(st error) == checksum ]]'
expect "nothing installed, no unit" '[[ ! -e $binf/ambxst-robo && ! -e $unitf ]]'
expect "systemctl never called" '[[ ! -s $T/stub/systemctl.log ]]'

echo "5. a tampered tarball"
sandbox
cp "$T/www/v$want/ambxst-robo-$want-$arch.tar.gz" "$T/tar.good"
printf 'x' >>"$T/www/v$want/ambxst-robo-$want-$arch.tar.gz"
run install --run r5; code=$?
cp "$T/tar.good" "$T/www/v$want/ambxst-robo-$want-$arch.tar.gz"
expect "refused" '[[ $code == 1 && $(st error) == checksum && ! -e $binf/ambxst-robo ]]'

echo "6. no release, no cargo"
sandbox
mv "$T/www/v$want" "$T/www/gone"
run install --run r6; code=$?
mv "$T/www/gone" "$T/www/v$want"
expect "error=download" '[[ $code == 1 && $(st error) == download && ! -e $binf/ambxst-robo ]]'

echo "7. developer setups are left alone"
sandbox
EXTRA_ENV=(AMBXST_ROBO_DEV=1)
run install --run r7; code=$?
EXTRA_ENV=()
expect "AMBXST_ROBO_DEV=1: skipped" '[[ $code == 0 && $(st phase) == skipped && ! -e $binf/ambxst-robo && ! -s $T/stub/systemctl.log ]]'
sandbox
mkdir -p "$T/home/.config/ambxst-robo"; touch "$T/home/.config/ambxst-robo/dev"
run install; code=$?
expect "~/.config/ambxst-robo/dev: skipped" '[[ $code == 0 && $(st phase) == skipped && ! -e $binf/ambxst-robo ]]'
expect "check says dev" '[[ "$(run check)" == state=dev* ]]'
sandbox
sed -i 's/^build=public$/build=personal/' "$T/mod/RELEASE"
run install; code=$?
expect "personal build: skipped" '[[ $code == 0 && $(st phase) == skipped && ! -e $binf/ambxst-robo ]]'
run install --force; code=$?
expect "personal build --force: installs" '[[ $code == 0 && $(st phase) == done && -x $binf/ambxst-robo ]]'
sed -i 's/^build=personal$/build=public/' "$T/mod/RELEASE"

if (( source_too )); then
  echo "8. no release for this machine: built from the tagged sources with cargo"
  sandbox
  mkdir -p "$T/srcpack/ambxst-robo-$want"
  tar -C "$here" --exclude=core/target --exclude=__pycache__ -cf - core | tar -C "$T/srcpack/ambxst-robo-$want" -xf -
  tar -C "$T/srcpack" -czf "$T/www/src.tar.gz" "ambxst-robo-$want"
  mv "$T/www/v$want" "$T/www/gone"
  ln -s "$HOME/.cargo/bin/cargo" "$T/stub/cargo"
  EXTRA_ENV=(RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_TOOLCHAIN=stable)
  run install --run r8; code=$?
  EXTRA_ENV=()
  rm -f "$T/stub/cargo"
  mv "$T/www/gone" "$T/www/v$want"
  expect "built and installed" '[[ $code == 0 && $(st phase) == done && "$("$binf/ambxst-robo" --version)" == "ambxst-robo $want" ]]'
fi

echo "$pass passed, $failn failed"
(( failn == 0 ))
