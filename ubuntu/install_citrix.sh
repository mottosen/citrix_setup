#!/usr/bin/env bash
#
# install_citrix.sh
#
# Purpose (2/3): install the Citrix client from the local .deb packages in the
# shared ../citrix_files/ dir, then copy the staged HTTPS CA certificates into
# the Citrix keystore so the client trusts the gateway (fixes "SSL error 61").
#
# ../citrix_files/ (shared with the NixOS setup) must contain an icaclient_*.deb
# and a ctxusb_*.deb (the newest match of each is used).
#
# Usage:
#   ./install_citrix.sh
#
# Env vars:
#   DEB_DIR     override the package dir (default: <repo>/citrix_files)
#   CERT_DIR    staging dir produced by ensure_certificates.sh
#               (default: <script dir>/certs)
#   SKIP_CERTS  set to 1 to install the packages only, without touching certs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/../shared" && pwd)"
. "$SHARED_DIR/common.sh"

# Exported so the ensure_certificates.sh sub-run (now in ../shared) stages into
# the same dir we later read from, instead of its own default next to itself.
export CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"
SKIP_CERTS="${SKIP_CERTS:-0}"

# Optional components the installer normally prompts for (debconf). Override with
# env vars (yes/no), e.g.  APP_PROTECTION=no ./install_citrix.sh
# Set INTERACTIVE=1 to restore the original interactive prompts instead.
INTERACTIVE="${INTERACTIVE:-0}"
APP_PROTECTION="${APP_PROTECTION:-yes}"  # anti-keylogging/screen-capture; required by the VDI. IRREVERSIBLE (uninstall to remove)
DEVICE_TRUST="${DEVICE_TRUST:-no}"       # deviceTRUST component
EPA="${EPA:-no}"                         # Endpoint Analysis component

ICAROOT="/opt/Citrix/ICAClient"
CACERTS="$ICAROOT/keystore/cacerts"
REHASH="$ICAROOT/util/ctx_rehash"

log_banner "install_citrix"

# ---- 1. resolve the package directory --------------------------------------
DEB_DIR="${DEB_DIR:-$SCRIPT_DIR/../citrix_files}"
[ -d "$DEB_DIR" ] || die "package directory not found: $DEB_DIR (expected the shared citrix_files/ dir with icaclient_*.deb and ctxusb_*.deb)"

# Pick the newest match of each package (version-sorted).
icaclient_deb=$(ls -1 "$DEB_DIR"/icaclient_*.deb 2>/dev/null | sort -V | tail -1 || true)
ctxusb_deb=$(ls -1 "$DEB_DIR"/ctxusb_*.deb 2>/dev/null | sort -V | tail -1 || true)

[ -n "$icaclient_deb" ] || die "no icaclient_*.deb found in $DEB_DIR"
[ -n "$ctxusb_deb" ]    || die "no ctxusb_*.deb found in $DEB_DIR"

icaclient_deb=$(realpath "$icaclient_deb")
ctxusb_deb=$(realpath "$ctxusb_deb")

log "icaclient package: $(basename "$icaclient_deb")"
log "ctxusb package   : $(basename "$ctxusb_deb")"

# ---- 2. install the packages (apt resolves dependencies for local debs) ----
if [ "$INTERACTIVE" = "1" ]; then
	# Interactive: prompts must stay visible, so this path is NOT redirected.
	log "Installing Citrix packages interactively (~400MB) ..."
	if ! sudo apt-get install -y "$icaclient_deb" "$ctxusb_deb"; then
		warn "apt install failed; retrying with dpkg + apt-get -f install ..."
		sudo dpkg -i "$icaclient_deb" "$ctxusb_deb" || true
		sudo apt-get install -f -y
	fi
else
	# Preseed the answers the interactive installer would ask, so the install is
	# non-interactive and repeatable. (debconf-set-selections ships in debconf-utils.)
	command -v debconf-set-selections >/dev/null 2>&1 || \
		run "Installing debconf-utils" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y debconf-utils
	log "Selecting components: app_protection=$APP_PROTECTION devicetrust=$DEVICE_TRUST epa=$EPA"
	sudo debconf-set-selections >>"$LOG" 2>&1 <<-EOF
		icaclient app_protection/install_app_protection select $APP_PROTECTION
		icaclient devicetrust/install_devicetrust select $DEVICE_TRUST
		icaclient epa/install_epa select $EPA
	EOF

	if ! try_run "Installing Citrix packages (~400MB, please wait)" \
			sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$icaclient_deb" "$ctxusb_deb"; then
		warn "apt install failed; retrying via dpkg + dependency fix ..."
		try_run "Unpacking packages with dpkg" \
			sudo env DEBIAN_FRONTEND=noninteractive dpkg -i "$icaclient_deb" "$ctxusb_deb" || true
		run "Resolving dependencies" \
			sudo env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
	fi
fi

[ -d "$ICAROOT" ] || die "Citrix did not install to $ICAROOT as expected"
ok "Citrix client installed at $ICAROOT"

# ---- 2b. runtime libraries the .deb fails to declare -----------------------
# The self-service UI embeds WebKit; the deb under-declares its deps, so the
# GUI dies with "error while loading shared libraries". Install the usual
# suspects, then scan with ldd for anything still missing.
try_run "Installing GUI runtime dependencies the package omits" \
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
		libwoff1 \
		libwebkit2gtk-4.1-0 \
		libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
		libhyphen0 libenchant-2-2 libsecret-1-0 libmanette-0.2-0 \
		libsoup2.4-1 libopengl0 \
	|| warn "some optional runtime deps could not be installed (continuing)"

log "Scanning Citrix binaries for missing shared libraries ..."
missing=""
for bin in "$ICAROOT/selfservice" "$ICAROOT/wfica" \
		"$ICAROOT/AuthManagerDaemon" "$ICAROOT/ServiceRecord" "$ICAROOT/util/storebrowse"; do
	[ -x "$bin" ] || continue
	while IFS= read -r lib; do
		case "$missing" in *"$lib"*) ;; *) missing="$missing $lib" ;; esac
	done < <(ldd "$bin" 2>/dev/null | awk '/not found/ {print $1}')
done
if [ -n "$missing" ]; then
	warn "Still missing shared libraries:$missing"
	warn "Find the providing packages with, e.g.:  apt-file search <lib>   (sudo apt-get install apt-file && sudo apt-file update)"
else
	ok "All required shared libraries resolved."
fi

# ---- 3. deploy CA certificates into the Citrix keystore --------------------
if [ "$SKIP_CERTS" = "1" ]; then
	warn "SKIP_CERTS=1 — leaving the Citrix keystore untouched."
	echo
	ok "Done."
	exit 0
fi

STAGE="$CERT_DIR/staged"
if ! ls "$STAGE"/*.pem >/dev/null 2>&1; then
	warn "No staged certificates in $STAGE."
	if [ -x "$SHARED_DIR/ensure_certificates.sh" ]; then
		# Resolve the host now so the sub-run inherits it (no second prompt).
		resolve_citrix_host
		log "Running ensure_certificates.sh to fetch and stage them ..."
		"$SHARED_DIR/ensure_certificates.sh"
	else
		die "run ../shared/ensure_certificates.sh first to stage the CA certificates"
	fi
fi
ls "$STAGE"/*.pem >/dev/null 2>&1 || die "still no staged certificates in $STAGE"

log "Copying CA certificates into $CACERTS ..."
sudo mkdir -p "$CACERTS"
count=0
for cert in "$STAGE"/*.pem; do
	# Citrix expects PEM files; keep a stable, collision-free name.
	dest="$CACERTS/$(basename "${cert%.pem}").pem"
	sudo cp "$cert" "$dest"
	count=$((count + 1))
done
ok "Copied $count certificate(s) into the Citrix keystore."

# ---- 4. rehash so Citrix can find them (creates <hash>.0 symlinks) ---------
[ -x "$REHASH" ] || die "ctx_rehash not found at $REHASH"
run "Rehashing the Citrix keystore" sudo "$REHASH"

# Confirm hash symlinks now exist.
if ls "$CACERTS"/*.0 >/dev/null 2>&1; then
	ok "Hash symlinks present in keystore ($(ls "$CACERTS"/*.0 | wc -l) total)."
else
	warn "No <hash>.0 symlinks found after rehash — Citrix may still not trust the certs."
fi

echo
ok "Installation complete."
echo "    Launch the client with:  /opt/Citrix/ICAClient/selfservice"
echo "    Then add the account:     https://${CITRIX_HOST:-<your Citrix gateway>}"
