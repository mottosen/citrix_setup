#!/usr/bin/env bash
#
# uninstall_citrix.sh
#
# Purpose (3/3): completely remove the Citrix client and all related files and
# per-user configuration, so a different version can be installed cleanly.
#
# Removes:
#   - the icaclient and ctxusb packages (purge)
#   - the /opt/Citrix install tree (incl. the cert keystore)
#   - per-user config (~/.ICAClient, ~/.config/Citrix*, ~/.local/share/Citrix*)
#   - the root CA optionally installed by ensure_certificates.sh --install-system
#
# Leaves the mounted directory and the staged certs (certs/) untouched.
#
# By default it does NOT remove the generic GUI runtime libraries that
# install_citrix.sh pulls in (libwoff1, libwebkit2gtk, GStreamer, ...): other
# software may use them, and the next Citrix version needs them anyway. Pass
# --deps to remove them too for a full wipe.
#
# Usage:
#   ./uninstall_citrix.sh [--deps]

set -euo pipefail

REMOVE_DEPS=0
for arg in "$@"; do
	case "$arg" in
		--deps) REMOVE_DEPS=1 ;;
		-h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 1 ;;
	esac
done

# ---- helpers ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

log_banner "uninstall_citrix"

# ---- 1. purge packages -----------------------------------------------------
try_run "Purging Citrix packages" \
	sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y icaclient ctxusb \
	|| warn "apt purge reported no packages (continuing)"
# Fallback in case apt didn't know them but dpkg does.
try_run "Removing via dpkg (fallback)" sudo dpkg --purge icaclient ctxusb || true
try_run "Autoremoving unused dependencies" \
	sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true

# ---- 2. remove the install tree --------------------------------------------
if [ -d /opt/Citrix ]; then
	log "Removing /opt/Citrix ..."
	sudo rm -rf /opt/Citrix
fi
# Drop an empty parent if it's left behind.
[ -d /opt/Citrix ] || true

# ---- 3. remove per-user configuration --------------------------------------
# Resolve the real invoking user's home even when run via sudo.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
	USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
	USER_HOME="$HOME"
fi

log "Removing per-user Citrix config under $USER_HOME ..."
rm -rf \
	"$USER_HOME/.ICAClient" \
	"$USER_HOME"/.config/Citrix* \
	"$USER_HOME"/.local/share/Citrix* \
	2>/dev/null || true

# ---- 4. remove a system-trusted root we may have installed ------------------
# ensure_certificates.sh --install-system writes this fixed, domain-agnostic name.
if [ -f "/usr/local/share/ca-certificates/$SYS_CA_NAME" ]; then
	log "Removing system-installed CA: $SYS_CA_NAME"
	sudo rm -f "/usr/local/share/ca-certificates/$SYS_CA_NAME"
	sudo update-ca-certificates --fresh >/dev/null 2>&1 || true
fi

# ---- 5. optionally remove the GUI runtime libs install_citrix.sh added ------
if [ "$REMOVE_DEPS" = "1" ]; then
	warn "--deps: removing generic GUI runtime libraries (may affect other apps)."
	# Mirror the list install_citrix.sh installs. apt skips any that are still
	# required by another package or are not installed.
	try_run "Removing GUI runtime libraries" \
		sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
			libwoff1 \
			libwebkit2gtk-4.1-0 \
			libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
			libhyphen0 libenchant-2-2 libsecret-1-0 libmanette-0.2-0 \
		|| warn "some libs were not removed (still required or absent)"
	try_run "Autoremoving unused dependencies" \
		sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
fi

# ---- 6. report -------------------------------------------------------------
echo
if dpkg -l 2>/dev/null | grep -Eq '^\w+\s+(icaclient|ctxusb)\s'; then
	warn "Some Citrix packages still appear installed — check 'dpkg -l | grep -E \"icaclient|ctxusb\"'."
else
	ok "Citrix packages removed."
fi
[ -d /opt/Citrix ] && warn "/opt/Citrix still exists." || ok "/opt/Citrix removed."
ok "Uninstall complete. You can now run ./install_citrix.sh for a clean retry."
