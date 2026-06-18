#!/usr/bin/env bash
#
# common.sh — shared helpers for the Citrix scripts. Meant to be sourced, not run.
#
# Keeping the gateway hostname (and other site-specific bits) out of the scripts
# means this directory can be shared with colleagues without leaking internal
# infrastructure details. Each person supplies their own hostname at runtime.

# ---- pretty logging --------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---- quiet command runner --------------------------------------------------
# Noisy command output (apt/dpkg/etc.) goes to $LOG; the user only sees the
# high-level step. The full log is shown/pointed to only when something fails.
LOG="${LOG:-$SCRIPT_DIR/logs.txt}"

# Append a session banner so a single log file stays readable across runs.
log_banner() {
	{ printf '\n########## %s @ %s ##########\n' "${1:-$(basename "$0")}" "$(date '+%Y-%m-%d %H:%M:%S')"; } >>"$LOG"
}

# run "Step shown to user" cmd args...
# Runs the command quietly; on failure prints the log tail and aborts.
run() {
	local desc="$1"; shift
	log "$desc"
	{ printf '\n===== %s =====\n$ %s\n' "$desc" "$*"; } >>"$LOG"
	local rc=0
	"$@" >>"$LOG" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "FAILED: $desc (exit $rc) — last 20 lines of $(basename "$LOG"):"
		tail -n 20 "$LOG" >&2
		die "full log: $LOG"
	fi
}

# Like run() but returns the exit status instead of aborting, so the caller can
# fall back to another approach. Use only in a conditional (if ! try_run ...).
try_run() {
	local desc="$1"; shift
	log "$desc"
	{ printf '\n===== %s (soft) =====\n$ %s\n' "$desc" "$*"; } >>"$LOG"
	"$@" >>"$LOG" 2>&1
}

# Fixed, domain-agnostic filename for the root CA we may add to the system trust
# store. Shared by ensure_certificates.sh (install) and uninstall_citrix.sh
# (removal) so the gateway hostname never has to be hard-coded anywhere.
SYS_CA_NAME="citrix-gateway-root.crt"

# Local, git-ignored file that remembers the user's gateway hostname so they are
# only prompted once. Never commit this — it is listed in .gitignore.
HOST_CONF="${HOST_CONF:-$SCRIPT_DIR/.citrix-host}"

# Resolve the Citrix gateway hostname into $CITRIX_HOST, in priority order:
#   1. an existing $CITRIX_HOST environment variable (for automation)
#   2. a previously-saved value in $HOST_CONF
#   3. an interactive prompt (optionally remembered for next time)
resolve_citrix_host() {
	if [ -n "${CITRIX_HOST:-}" ]; then
		export CITRIX_HOST
		return 0
	fi

	if [ -f "$HOST_CONF" ]; then
		CITRIX_HOST="$(head -n1 "$HOST_CONF" | tr -d '[:space:]')"
	fi

	if [ -z "${CITRIX_HOST:-}" ]; then
		[ -t 0 ] || die "CITRIX_HOST is not set and there is no terminal to prompt. Run: CITRIX_HOST=<gateway> $0 ..."
		printf 'Enter the Citrix gateway hostname (e.g. vdi.example.com): '
		read -r CITRIX_HOST
		CITRIX_HOST="$(printf '%s' "$CITRIX_HOST" | tr -d '[:space:]')"
		[ -n "$CITRIX_HOST" ] || die "no hostname entered"
		printf 'Remember this hostname for next time? [Y/n] '
		read -r _ans
		case "$_ans" in
			[Nn]*) : ;;
			*) printf '%s\n' "$CITRIX_HOST" >"$HOST_CONF" && log "Saved to $(basename "$HOST_CONF") (git-ignored)." ;;
		esac
	fi

	export CITRIX_HOST
}
