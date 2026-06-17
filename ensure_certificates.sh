#!/usr/bin/env bash
#
# ensure_certificates.sh
#
# Purpose (1/3): make sure the TLS certificate chain for the Citrix gateway is
# correct on this Ubuntu VM and stage it so install_citrix.sh can copy it into
# the Citrix keystore.
#
# Background: the Linux Citrix Workspace App / ICA client does NOT use the system
# trust store (/etc/ssl/certs) or the browser's NSS DB. It has its own keystore
# and, crucially, it does not auto-fetch missing intermediate CAs. So we must
# stage the *full* CA chain (root + every intermediate) in PEM form.
#
# This script:
#   - connects to the gateway and downloads the chain it serves (leaf + intermediates)
#   - resolves the root CA from the system trust store via the issuer hash
#   - prints the chain so it can be audited
#   - verifies the leaf validates against the system store
#   - stages the CA certs (root + intermediates) into $CERT_DIR for install_citrix.sh
#
# Env vars:
#   CITRIX_HOST   gateway hostname  (prompted for if unset; see common.sh)
#   CITRIX_PORT   gateway port               (default: 443)
#   CERT_DIR      staging dir for CA certs   (default: <script dir>/certs)
#
# Flags:
#   --install-system   also install the root CA into the VM system trust store
#                      (/usr/local/share/ca-certificates + update-ca-certificates).
#                      Usually unnecessary because the browser already trusts it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/common.sh"

CITRIX_PORT="${CITRIX_PORT:-443}"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/certs}"
INSTALL_SYSTEM=0

for arg in "$@"; do
	case "$arg" in
		--install-system) INSTALL_SYSTEM=1 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) die "unknown argument: $arg" ;;
	esac
done

need_cmd openssl
need_cmd awk

log_banner "ensure_certificates"
resolve_citrix_host

# ---- 1. fetch the chain the server serves ----------------------------------
mkdir -p "$CERT_DIR"
RAW="$CERT_DIR/_chain_${CITRIX_HOST}.pem"

log "Fetching certificate chain from ${CITRIX_HOST}:${CITRIX_PORT} ..."
if ! openssl s_client -connect "${CITRIX_HOST}:${CITRIX_PORT}" \
		-servername "${CITRIX_HOST}" -showcerts </dev/null >"$RAW" 2>/dev/null; then
	die "could not connect to ${CITRIX_HOST}:${CITRIX_PORT} (network/VPN up?)"
fi

grep -q "BEGIN CERTIFICATE" "$RAW" || die "no certificates returned by ${CITRIX_HOST}"

# Split the concatenated PEM blob into one file per certificate.
# Index 1 = leaf (the server cert, not a CA); 2..N = intermediates.
rm -f "$CERT_DIR/${CITRIX_HOST}-chain-"*.pem 2>/dev/null || true
awk -v dir="$CERT_DIR" -v host="$CITRIX_HOST" '
	/-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%s-chain-%02d.pem", dir, host, n) }
	n > 0 { print > f }
' "$RAW"
rm -f "$RAW"

mapfile -t CHAIN < <(ls -1 "$CERT_DIR/${CITRIX_HOST}-chain-"*.pem 2>/dev/null | sort)
[ "${#CHAIN[@]}" -ge 1 ] || die "failed to split certificate chain"

log "Server returned ${#CHAIN[@]} certificate(s):"
for c in "${CHAIN[@]}"; do
	subj=$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject= *//')
	iss=$(openssl x509 -in "$c" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
	printf '    %s\n      subject: %s\n      issuer : %s\n' "$(basename "$c")" "$subj" "$iss"
done

LEAF="${CHAIN[0]}"
TOP="${CHAIN[-1]}"   # topmost cert the server sent (highest intermediate, or leaf)

# ---- helper: download a URL to a file (curl or wget) -----------------------
download() {
	local url="$1" out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$out"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "$url" -O "$out"
	else
		return 2
	fi
}

# ---- helper: find a cert's issuer in the system trust store ----------------
find_issuer_in_store() {
	local cert="$1" h cand
	h=$(openssl x509 -in "$cert" -noout -issuer_hash 2>/dev/null) || return 1
	for cand in "/etc/ssl/certs/${h}."*; do
		[ -e "$cand" ] || continue
		printf '%s\n' "$cand"
		return 0
	done
	return 1
}

# ---- helper: fetch a cert's issuer via its AIA "CA Issuers" URL ------------
# Emulates what a browser does when the server omits intermediates: the cert
# carries the URL of its issuing CA in the Authority Information Access ext.
fetch_issuer_via_aia() {
	local cert="$1" out="$2" url tmp
	url=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
		| awk '/CA Issuers - URI:/ { sub(/.*URI:/, ""); print; exit }')
	[ -n "$url" ] || return 1
	tmp=$(mktemp)
	if ! download "$url" "$tmp"; then rm -f "$tmp"; return 1; fi
	# The blob may be DER, PEM, or PKCS#7 (.p7c/.p7b); try each form.
	if   openssl x509  -in "$tmp" -inform DER -out "$out" 2>/dev/null; then :
	elif openssl x509  -in "$tmp" -inform PEM -out "$out" 2>/dev/null; then :
	elif openssl pkcs7 -in "$tmp" -inform DER -print_certs 2>/dev/null | openssl x509 -out "$out" 2>/dev/null; then :
	elif openssl pkcs7 -in "$tmp" -inform PEM -print_certs 2>/dev/null | openssl x509 -out "$out" 2>/dev/null; then :
	else rm -f "$tmp" "$out"; return 1; fi
	rm -f "$tmp"
	printf '%s\n' "$url"
}

# ---- 2. complete the chain & stage the CA certs (intermediates + root) ------
# install_citrix.sh copies every *.pem in $CERT_DIR/staged into the Citrix keystore.
STAGE="$CERT_DIR/staged"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Copy a CA cert into the staging dir under a readable, unique name; echo the path.
stage_ca() {
	local src="$1" idx="$2" cn slug
	cn=$(openssl x509 -in "$src" -noout -subject 2>/dev/null \
		| sed -n 's/.*CN *= *//p' | sed 's/[^A-Za-z0-9._-]/_/g')
	[ -n "$cn" ] || cn="ca"
	slug=$(printf 'ca-%02d-%s.pem' "$idx" "$cn")
	cp "$src" "$STAGE/$slug"
	printf '%s\n' "$STAGE/$slug"
}

staged=0
idx=0

# Any intermediates the server already sent (chain entries 2..N).
for i in "${!CHAIN[@]}"; do
	[ "$i" -eq 0 ] && continue   # skip the leaf
	idx=$((idx + 1)); stage_ca "${CHAIN[$i]}" "$idx" >/dev/null; staged=$((staged + 1))
done

# Walk up from the topmost cert we hold, resolving each issuer until we reach a
# self-signed root: prefer the system trust store, fall back to AIA download.
log "Completing the certificate chain ..."
cur="$TOP"
work=$(mktemp -d)
guard=0
while :; do
	guard=$((guard + 1)); [ "$guard" -gt 10 ] && { warn "chain unexpectedly long; stopping"; break; }

	subj_hash=$(openssl x509 -in "$cur" -noout -hash 2>/dev/null)
	iss_hash=$(openssl x509 -in "$cur" -noout -issuer_hash 2>/dev/null)
	if [ "$subj_hash" = "$iss_hash" ]; then
		ok "Reached self-signed root: $(openssl x509 -in "$cur" -noout -subject | sed 's/^subject= *//')"
		break
	fi

	if found=$(find_issuer_in_store "$cur"); then
		idx=$((idx + 1)); dest=$(stage_ca "$found" "$idx"); staged=$((staged + 1))
		ok "Issuer found in system store: $(openssl x509 -in "$dest" -noout -subject | sed 's/^subject= *//')"
		cur="$dest"
		continue
	fi

	next="$work/issuer-${guard}.pem"
	if url=$(fetch_issuer_via_aia "$cur" "$next"); then
		idx=$((idx + 1)); dest=$(stage_ca "$next" "$idx"); staged=$((staged + 1))
		ok "Fetched missing intermediate via AIA ($url):"
		printf '        %s\n' "$(openssl x509 -in "$dest" -noout -subject | sed 's/^subject= *//')"
		cur="$dest"
		continue
	fi

	warn "Could not resolve the issuer of:"
	warn "    $(openssl x509 -in "$cur" -noout -subject | sed 's/^subject= *//')"
	warn "Its issuer is not in /etc/ssl/certs and no AIA URL was usable."
	warn "Export the issuing/root CA manually and drop it into: $CERT_DIR"
	break
done
rm -rf "$work"

# Also pick up any certs the user dropped into $CERT_DIR manually.
shopt -s nullglob
for extra in "$CERT_DIR"/*.crt "$CERT_DIR"/*.cer; do
	base=$(basename "$extra")
	# normalize to PEM into the staging dir
	if openssl x509 -in "$extra" -noout >/dev/null 2>&1; then
		openssl x509 -in "$extra" -out "$STAGE/${base%.*}.pem" 2>/dev/null && staged=$((staged + 1))
	else
		warn "skipping $base (not a readable X.509 certificate)"
	fi
done
shopt -u nullglob

[ "$staged" -gt 0 ] || die "no CA certificates were staged; nothing for Citrix to trust"
ok "Staged $staged CA certificate(s) in: $STAGE"

# ---- 4. sanity-check the leaf against the system store ---------------------
if openssl verify "$LEAF" >/dev/null 2>&1; then
	ok "Leaf certificate validates against the system trust store."
else
	# Try building with what we staged, so we can tell the user whether the
	# chain is complete even if the system store lacks the root.
	if cat "$STAGE"/*.pem >"$CERT_DIR/_castack.pem" 2>/dev/null && \
		openssl verify -CAfile "$CERT_DIR/_castack.pem" "$LEAF" >/dev/null 2>&1; then
		ok "Leaf validates against the staged chain (root+intermediates complete)."
	else
		warn "Leaf does not fully validate yet. The staged chain may be missing the root."
		warn "If the browser works, export the corporate root CA and place it in: $CERT_DIR"
	fi
	rm -f "$CERT_DIR/_castack.pem"
fi

# ---- 5. optional: trust at the system level --------------------------------
if [ "$INSTALL_SYSTEM" -eq 1 ]; then
	# Find the self-signed root among the staged CA certs.
	root_pem=""
	for c in "$STAGE"/*.pem; do
		[ -e "$c" ] || continue
		[ "$(openssl x509 -in "$c" -noout -hash 2>/dev/null)" = \
		  "$(openssl x509 -in "$c" -noout -issuer_hash 2>/dev/null)" ] || continue
		root_pem="$c"; break
	done
	if [ -n "$root_pem" ]; then
		# Fixed, domain-agnostic name (SYS_CA_NAME) so uninstall can find it.
		sudo cp "$root_pem" "/usr/local/share/ca-certificates/$SYS_CA_NAME"
		run "Updating the system trust store" sudo update-ca-certificates
		ok "System trust store updated."
	else
		warn "--install-system: no self-signed root was staged; skipping."
	fi
fi

echo
ok "Done. Next: run  ./install_citrix.sh  to install and wire up Citrix."
