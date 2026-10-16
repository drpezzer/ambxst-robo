#!/usr/bin/env bash
# Ambxst Robo: installs or updates ambxst-robo (the daemon) and its hook relay
# so they match the mod, and runs the daemon as a systemd user service. The
# shell runs it (modules/robo/RoboCore.qml) on start, detached under
# systemd-run, so the shell never waits on it:
#
#   robo-core-install.sh check                prints: state=<ok|missing|outdated|unit|dev> installed=<v> want=<v> active=<…>
#   robo-core-install.sh install [--run ID]   download (or build), install, (re)start the service
#
#   --version X   the version wanted (default: version= in RELEASE beside this script)
#   --force       install even where the RELEASE file says build=personal
#
# install: downloads ambxst-robo-<version>-<arch>.tar.gz and SHA256SUMS from
# the GitHub release v<version>, checks the sha256, installs ambxst-robo and
# ambxst-robo-hook into ~/.local/bin (new inodes: the running daemon is left
# alone), writes ~/.config/systemd/user/ambxst-robo.service, enables it and
# starts it — or restarts it once no Robo chat turn is running (a `claude -p`
# child of the daemon), so an update never cuts a reply off. Without a
# download for this machine (another arch, a binary that does not run here)
# it builds the tagged sources with cargo if cargo is there.
#
# Progress goes to the status file as key=value lines (run, phase, error,
# detail, version) for the shell to show; the log to
# ~/.local/state/ambxst-robo/core-install.log.
#
# Never touches a developer setup: AMBXST_ROBO_DEV=1, a file
# ~/.config/ambxst-robo/dev, or build=personal in RELEASE (without --force).
#
# Environment (tests, mirrors):
#   AMBXST_ROBO_RELEASE_BASE  default https://github.com/drpezzer/ambxst-robo/releases/download
#                             (assets at $BASE/v<version>/…; plain http only to 127.0.0.1/localhost)
#   AMBXST_ROBO_SOURCE_URL    the cargo fallback's source tarball
#                             (default https://github.com/drpezzer/ambxst-robo/archive/refs/tags/v<version>.tar.gz)
#   AMBXST_ROBO_BIN_DIR       default ~/.local/bin
#   AMBXST_ROBO_STATUS        default $XDG_RUNTIME_DIR/ambxst-robo-install.status
#   AMBXST_ROBO_NO_WAIT=1     restart without waiting for a chat turn to end
#   AMBXST_ROBO_WAIT_MAX      seconds to wait for it (default 7200)
set -uo pipefail
umask 022

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
repo_base="https://github.com/drpezzer/ambxst-robo"
release_base="${AMBXST_ROBO_RELEASE_BASE:-$repo_base/releases/download}"
bin="${AMBXST_ROBO_BIN_DIR:-$HOME/.local/bin}"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
unit_dir="$config/systemd/user"
unit="ambxst-robo.service"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ambxst-robo"
runtime="${XDG_RUNTIME_DIR:-/tmp}"
status_file="${AMBXST_ROBO_STATUS:-$runtime/ambxst-robo-install.status}"
log="$state_dir/core-install.log"
# systemd user services do not get the login shell's PATH: where cargo usually is.
PATH="$PATH:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

mode="${1:-}"; [[ $# -gt 0 ]] && shift
want=""; run=""; force=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) want="${2:-}"; shift 2 ;;
    --run) run="${2:-}"; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "robo-core-install: unknown option $1" >&2; exit 2 ;;
  esac
done

release_value() {  # key → value from RELEASE (key=value lines)
  [[ -f $here/RELEASE ]] || return 0
  sed -n "s/^$1=//p" "$here/RELEASE" | head -n1
}
[[ -n $want ]] || want="$(release_value version)"
build="$(release_value build)"

is_dev() {
  [[ ${AMBXST_ROBO_DEV:-} == 1 || -e $config/ambxst-robo/dev ]] && return 0
  [[ $build == personal ]] && (( ! force ))
}

installed_version() {  # the version of the daemon in $bin, "" if none (or it does not run)
  [[ -x $bin/ambxst-robo ]] || return 0
  "$bin/ambxst-robo" --version 2>/dev/null | sed -n 's/^ambxst-robo //p' | head -n1
}

unit_text() {
  local exec="%h/.local/bin/ambxst-robo"
  [[ $bin == "$HOME/.local/bin" ]] || exec="$bin/ambxst-robo"
  cat <<EOF
# Ambxst Robo's daemon. Written by the Ambxst Robo mod (robo-core-install.sh),
# rewritten when the mod updates the daemon: put your own changes in a drop-in
# (systemctl --user edit ambxst-robo.service), not here.
[Unit]
Description=Ambxst Robo daemon (hooks, approvals, chat, integrations)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$exec
Restart=on-failure
RestartSec=2
# Keeps ~/.local/share/ambxst-robo/bin/ambxst-robo-hook (the relay agents' hooks
# run) the same version as the daemon.
Environment=AMBXST_ROBO_INSTALL_RELAY=1

[Install]
WantedBy=graphical-session.target
EOF
}

unit_current() { [[ -f $unit_dir/$unit ]] && cmp -s <(unit_text) "$unit_dir/$unit"; }

# ── check ────────────────────────────────────────────────────────────────────
if [[ $mode == check ]]; then
  have="$(installed_version)"
  if is_dev; then st=dev
  elif [[ -z $have ]]; then st=missing
  elif [[ $have != "$want" ]]; then st=outdated
  elif ! unit_current; then st=unit
  else st=ok
  fi
  active="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
  echo "state=$st installed=${have:-none} want=${want:-none} active=${active:-unknown}"
  exit 0
fi
[[ $mode == install ]] || { echo "usage: robo-core-install.sh check|install [--version X] [--run ID] [--force]" >&2; exit 2; }

# ── install ──────────────────────────────────────────────────────────────────
mkdir -p "$state_dir" "$(dirname "$status_file")"
# Keep the log short: the last runs only.
if [[ -f $log ]] && (( $(stat -c %s "$log" 2>/dev/null || echo 0) > 262144 )); then
  tail -c 65536 "$log" >"$log.tmp" && mv -f "$log.tmp" "$log"
fi
exec >>"$log" 2>&1
echo "── $(date -Is) robo-core-install $want (run ${run:-none})"

phase=""
status() {  # phase [error [detail]]
  phase="$1"
  local detail="${3:-}"
  detail="${detail//$'\n'/ }"
  printf 'run=%s\nphase=%s\nerror=%s\ndetail=%s\nversion=%s\n' "$run" "$1" "${2:-}" "${detail:0:300}" "$want" >"$status_file.tmp" \
    && mv -f "$status_file.tmp" "$status_file"
  echo "[$1] ${2:-} ${detail}"
}
fail() { status error "$1" "${2:-}"; exit 1; }
tmp=""
cleanup() {
  local code=$?
  [[ -n $tmp && -d $tmp ]] && rm -rf "$tmp"
  if [[ $phase != "done" && $phase != error && $phase != skipped ]]; then
    status error internal "stopped during '$phase' (exit $code)"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -n $want ]] || fail internal "no version given and no RELEASE file"
[[ $want =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail internal "bad version '$want'"
if is_dev; then status skipped "" "developer setup (AMBXST_ROBO_DEV, ~/.config/ambxst-robo/dev or a personal build)"; exit 0; fi

# One installer at a time (a shell reload starts another check).
exec 9>"$runtime/ambxst-robo-install.lock"
if command -v flock >/dev/null && ! flock -n 9; then
  echo "another install is running"; phase=skipped; exit 0
fi

status checking
for tool in curl tar sha256sum install systemctl; do
  command -v "$tool" >/dev/null || fail tools "$tool"
done

case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) arch="" ;;
esac

proto="=https"
[[ $release_base =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/|$) ]] && proto="=http,https"
fetch() {  # url → file
  curl -fsSL --proto "$proto" --tlsv1.2 --retry 2 --connect-timeout 20 --max-time 600 -o "$2" "$1"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ambxst-robo-install.XXXXXX")" || fail internal "mktemp"
new_dir=""   # where the new ambxst-robo and ambxst-robo-hook are

runs_as_want() { [[ "$("$1/ambxst-robo" --version 2>/dev/null)" == "ambxst-robo $want" && -x $1/ambxst-robo-hook ]]; }

from_release() {
  [[ -n $arch ]] || { why="arch"; reason="no prebuilt daemon for $(uname -m)"; return 1; }
  local name="ambxst-robo-$want-$arch.tar.gz" url="$release_base/v$want"
  status downloading
  if ! fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS" || ! fetch "$url/$name" "$tmp/$name"; then
    why="download"; reason="$url/$name"; return 1
  fi
  status verifying
  local expected actual
  expected="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$tmp/SHA256SUMS")"
  actual="$(sha256sum "$tmp/$name" | cut -d' ' -f1)"
  if [[ -z $expected || ${expected,,} != "$actual" ]]; then
    # Never fall back to building on a bad checksum: something is wrong with the download.
    fail checksum "$name: expected ${expected:-nothing in SHA256SUMS}, got $actual"
  fi
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/$name" -C "$tmp/x" --no-same-owner --no-same-permissions || { why="download"; reason="bad archive"; return 1; }
  local dir="$tmp/x/ambxst-robo-$want-$arch"
  chmod 755 "$dir/ambxst-robo" "$dir/ambxst-robo-hook" 2>/dev/null
  if ! runs_as_want "$dir"; then
    why="notrun"; reason="$("$dir/ambxst-robo" --version 2>&1 | head -n1)"; return 1
  fi
  new_dir="$dir"
}

from_source() {
  command -v cargo >/dev/null || return 1
  status building
  local url="${AMBXST_ROBO_SOURCE_URL:-$repo_base/archive/refs/tags/v$want.tar.gz}"
  local sproto="=https"
  [[ $url =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/|$) ]] && sproto="=http,https"
  curl -fsSL --proto "$sproto" --tlsv1.2 --retry 2 --connect-timeout 20 --max-time 600 -o "$tmp/src.tar.gz" "$url" \
    || fail download "$url"
  mkdir -p "$tmp/src"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1 --no-same-owner || fail download "bad source archive"
  [[ -f $tmp/src/core/Cargo.toml ]] || fail build "no core/Cargo.toml in the source archive"
  # The build's own target dir, kept between runs so a retry is quick.
  local target="${XDG_CACHE_HOME:-$HOME/.cache}/ambxst-robo/build"
  mkdir -p "$target"
  if ! (cd "$tmp/src/core" && CARGO_TARGET_DIR="$target" cargo build --release --locked); then
    fail build "cargo build failed (missing libdbus-1 headers or a C compiler?)"
  fi
  runs_as_want "$target/release" || fail build "the build is not version $want"
  new_dir="$target/release"
}

have="$(installed_version)"
updated=0
if [[ $have != "$want" || ! -x $bin/ambxst-robo-hook ]]; then
  why=""; reason=""
  if ! from_release; then
    echo "prebuilt daemon unusable: $why $reason"
    from_source || fail "$why" "$reason"
  fi
  status installing
  mkdir -p "$bin" || fail internal "cannot create $bin"
  for f in ambxst-robo ambxst-robo-hook; do
    # A new inode: the running daemon keeps its own ("text file busy" otherwise).
    if ! { install -m755 "$new_dir/$f" "$bin/.$f.new" && mv -f "$bin/.$f.new" "$bin/$f"; }; then
      fail internal "cannot install $bin/$f"
    fi
  done
  [[ "$(installed_version)" == "$want" ]] || fail internal "installed, but $bin/ambxst-robo is not $want"
  updated=1
fi

status installing
unit_changed=0
if ! unit_current; then
  mkdir -p "$unit_dir" || fail systemd "cannot create $unit_dir"
  if ! { unit_text >"$unit_dir/.$unit.new" && mv -f "$unit_dir/.$unit.new" "$unit_dir/$unit"; }; then
    fail systemd "cannot write $unit_dir/$unit"
  fi
  unit_changed=1
fi
if (( unit_changed )); then
  systemctl --user daemon-reload || fail systemd "systemctl --user daemon-reload"
fi
systemctl --user enable "$unit" || fail systemd "systemctl --user enable $unit"

active="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
if [[ $active == active || $active == activating || $active == reloading ]]; then
  pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  # A replaced binary reads "…/ambxst-robo (deleted)".
  if (( updated || unit_changed )) || [[ $exe != "$bin/ambxst-robo" ]]; then
    if [[ ${AMBXST_ROBO_NO_WAIT:-} != 1 ]]; then
      deadline=$(( $(date +%s) + ${AMBXST_ROBO_WAIT_MAX:-7200} ))
      while :; do
        pid="$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
        [[ -z $pid || $pid == 0 ]] && break
        # Running children only: a finished helper not reaped yet is no turn.
        # shellcheck disable=SC2009 # pgrep cannot leave zombies out
        ps --ppid "$pid" -o stat= 2>/dev/null | grep -qv '^Z' || break
        [[ $phase == waiting ]] || status waiting
        (( $(date +%s) < deadline )) || break
        sleep 3
      done
    fi
    status restarting
    systemctl --user restart "$unit" || fail systemd "systemctl --user restart $unit"
  fi
else
  status starting
  systemctl --user reset-failed "$unit" 2>/dev/null || true
  systemctl --user start "$unit" || fail systemd "systemctl --user start $unit"
fi
status "done"
echo "ambxst-robo $want ready"
