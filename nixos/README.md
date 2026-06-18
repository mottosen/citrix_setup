# Citrix Workspace App on NixOS (Vagrant + flakes)

A NixOS VM that runs the Citrix Workspace client — the NixOS counterpart to
[`../ubuntu`](../ubuntu/README.md). It solves the same **"SSL error 61"** (the
client's own keystore doesn't trust the gateway's CA chain) **declaratively**, and
goes further: it gets you all the way through gateway auth and into a live HDX
session. The one thing it does **not** deliver is **App Protection** — see
[Status](#status) and [App Protection](#app-protection-not-working-on-nixos).

Prerequisites (Nix dev shell, a provider, and the Citrix **tarball** in
[`../citrix_files/`](../citrix_files/README.md) — the version must match what the
flake's nixpkgs pins) are in the [top-level README](../README.md).

## Status

What works end-to-end on this VM:

- ✅ Boots reliably (root/boot mounted by UUID — see [notes](#notes--caveats)).
- ✅ GNOME desktop (GDM, autologin), viewable via SPICE/virt-manager.
- ✅ **SSL error 61** fixed — the gateway CA chain is baked into the ICA engine's
  keystore (`extraCerts` + `ctx_rehash`).
- ✅ **Self-service / AuthManager** trust fixed — the gateway chain is also placed
  in a system CA bundle the HTTPS auth path uses (see [certificates](#how-the-certificates-are-handled)).
- ✅ The gateway **web logon renders inside the Citrix app** (it needs a WebKit/GTK
  runtime that installing **Firefox** pulls in — see [the logon note](#logging-in)).
- ✅ Two-factor gateway logon (e.g. `DomainAndRSA`) completes, resources enumerate.
- ✅ A **desktop/app session launches** via `wfica` (software GL — the VM has no GPU).

What does **not** work:

- ❌ **App Protection** — not available on NixOS (unsupported platform + Wayland).
  Use the **Ubuntu VM** when you need it. Details below.

So: this VM is a fully usable Citrix client for general use; it is **not** the one
to rely on when App Protection is mandatory.

## How the certificates are handled

The gateway's CA chain is **not** committed (a corporate CA can disclose your
employer / internal PKI, and this is a public repo). `../shared/ensure_certificates.sh`
runs **inside the guest**, stages the chain into `/var/lib/citrix-certs/staged`
(VM-local), and the flake reads it (`nixos-rebuild --impure` — the only impurity).

Citrix has **two independent trust paths**, and both must be satisfied:

1. **ICA engine (`wfica`)** → the keystore `keystore/cacerts`. Fixed by
   `citrix_workspace.override { extraCerts = …; }` (the classic "SSL error 61").
2. **AuthManager / self-service** (the HTTPS to StoreFront) → the **system** CA
   store via libcurl/OpenSSL. NixOS's `ca-certificates.crt` holds only root
   _anchors_, so the gateway's missing **intermediate** (it omits it from the
   handshake; OpenSSL won't fetch via AIA) never lands there. The flake therefore
   builds an explicit combined bundle (public roots + staged chain) and points
   `SSL_CERT_FILE`/`CURL_CA_BUNDLE` at it via `environment.sessionVariables` **and**
   `/etc/environment.d` (so the GNOME-session-spawned Citrix processes inherit it).
   Without this the client hangs on "connecting" with curl error 60.

## Usage

```bash
# from the repo root, in a `nix develop` shell:
make nixos                  # prompts for the gateway host, provisions, then halts
make nixos PROVIDER=libvirt # or pick a provider
cd nixos && vagrant up      # start it yourself; then open the display, or: vagrant ssh
# in the guest desktop:
citrix_workspace            # or: selfservice
```

Provisioning is a single **bootstrap** step (one SSH session, so it survives the
`sshd` restart a rebuild triggers): the first `nixos-rebuild` installs Citrix + the
cert tools, then — in the same session — `ensure_certificates.sh` stages the gateway
CA chain and a second rebuild bakes it in. `make nixos-certs` re-runs just the cert
step on demand. The hostname comes from `CITRIX_HOST` or the git-ignored
`.citrix-host` at the repo root; if unset/unreachable the cert step is skipped
without failing `vagrant up`.

> **NixOS note:** `ensure_certificates.sh` resolves a missing root via the system
> trust store's per-hash files, which NixOS doesn't populate (single bundle). It
> falls back to AIA download, which usually completes the chain. If it can't, drop
> your corporate root CA into `/var/lib/citrix-certs/` before the rebuild.

## Viewing the desktop

GNOME on GDM with autologin as `vagrant` (GNOME 50 on 26.05 → a **Wayland** session;
Citrix runs via XWayland):

- **VirtualBox:** `vb.gui = true` opens the display window on `vagrant up`.
- **libvirt:** SPICE display — open it in **virt-manager**, or
  `virt-viewer --connect qemu:///system citrix-vm-nixos`.

**Clipboard (host↔guest):** works, via a `spice-vdagent` **user** service pinned to
XWayland (`DISPLAY=:0`) — nixpkgs' autostart doesn't set a display, so it would bail.
Reconnect the virt-manager console after boot if the clipboard doesn't sync
immediately. Fallback to push text in from a host SSH shell:
`printf '%s' 'text' | vagrant ssh -c 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 setsid wl-copy'`.

## Logging in

The gateway here uses **NetScaler web logon** (`/logon/LogonPoint`), which Citrix
renders in an **embedded WebKit view**. That view only renders because **Firefox** is
installed (it provides the WebKit/GTK/libsoup runtime the embedded view needs);
without a browser present, the logon spins forever and the client never shows the
form. With Firefox in, the app shows the credential form, completes two-factor
(`DomainAndRSA`) auth, enumerates resources, and launches the session via `wfica`.

The session renders with **software GL** (`LIBGL_ALWAYS_SOFTWARE=1`,
`GALLIUM_DRIVER=llvmpipe`, set in the session env): the VM has no GPU, so Mesa's
default ZINK/Vulkan path fails and the launch would otherwise report
"desktop not available".

## App Protection (not working on NixOS)

The flake _attempts_ App Protection (anti-keylogging / anti-screen-capture) — it
overrides `citrix_workspace` with `INSTALLER_YES = "yes"` (the App-Protection opt-in)
and runs GNOME + GDM, which Citrix requires for it. **In practice it does not engage
on this VM**, for two reasons:

1. **Unsupported platform.** Citrix supports App Protection only on specific distros
   (Ubuntu/Debian/RHEL/SUSE). NixOS isn't supported, and nixpkgs' `citrix_workspace`
   doesn't really wire up the add-on — flipping `INSTALLER_YES` only opts in; if the
   App-Protection binaries/driver aren't shipped/functional, there's nothing to
   activate ("component not available").
2. **Wayland.** App Protection's hooks are X11-oriented. GNOME 50 is Wayland-only
   (Citrix runs under XWayland), and Wayland isolates input/screen-capture, so the
   protection layer doesn't get the purchase it needs even if the component installed.

Making it work on NixOS would mean confirming/adding the App-Protection binaries
**and** an X11 GNOME session (GNOME 50 dropped Xorg — you'd pin older GNOME or a
different X11 desktop), possibly plus a kernel shim — a lot of effort with no
guarantee. **If you need App Protection, use the [Ubuntu VM](../ubuntu/README.md)**,
which is an officially supported platform.
