# Citrix Workspace App on Ubuntu (Vagrant)

A Vagrant VM (Ubuntu 24.04) that installs the Citrix Workspace client and fixes
**"SSL error 61"** by trusting the gateway's CA chain in the client's keystore —
the Ubuntu counterpart to the NixOS VM in [`../nixos`](../nixos/README.md).
Supports both VirtualBox and libvirt.

Prerequisites (Nix dev shell, a provider, and the Citrix `.deb`s in
[`../citrix_files/`](../citrix_files/README.md)) are in the
[top-level README](../README.md).

## Usage

```bash
# from the repo root, in a `nix develop` shell:
make ubuntu                  # prompts for the gateway host, provisions, then halts
make ubuntu PROVIDER=libvirt # or pick a provider
# make leaves the VM off so your next start is a clean boot (App Protection +
# desktop need it) — start it yourself:
cd ubuntu && vagrant up      # then open the display, or: vagrant ssh
```

Provisioning runs two steps automatically:

1. **desktop** — GNOME + GDM (required for the GUI and App Protection). Also
   installs the generic kernel, because the cloud image's `kvm` kernel ships no
   GPU/DRM drivers and GDM can't start a display without one. Snaps are blocked, so
   **Firefox** is installed as a real `.deb` from **Mozilla's APT repo** (Ubuntu's
   `firefox` package is only a snap shim); it provides the WebKit runtime Citrix's
   embedded gateway-logon view needs.
2. **citrix** — runs `install_citrix.sh` unattended: installs the `.deb`s and the
   GUI runtime libraries the package omits, stages the gateway CA chain, and wires
   it into the keystore (`+ ctx_rehash`).

The gateway hostname comes from `CITRIX_HOST` or the git-ignored `.citrix-host`
file at the repo root (`make ubuntu` prompts and saves it). Without it, only the
packages are installed; add the certs later with `make ubuntu-certs`.

> **App Protection** (`APP_PROTECTION=yes`, the default) requires GNOME + GDM and
> a reboot — that's why `make` halts the VM, so your next `vagrant up` is the
> clean boot that activates it. Caveat: with App Protection installed, in-place
> upgrades aren't supported — rebuild the VM to move versions.

## Installer options

`install_citrix.sh` honours these env vars. The `citrix` provisioner sets
`CITRIX_HOST` (and a writable `CERT_DIR`); edit it in the `Vagrantfile` to change
the others.

| Var                    | Default           | Meaning                                                          |
| ---------------------- | ----------------- | ---------------------------------------------------------------- |
| `CITRIX_HOST`          | _(prompted)_      | Gateway hostname; skips the prompt when set                      |
| `APP_PROTECTION`       | `yes`             | App Protection component (required by the VDI; **irreversible**) |
| `DEVICE_TRUST` / `EPA` | `no`              | Optional deviceTRUST / Endpoint Analysis components              |
| `DEB_DIR`              | `../citrix_files` | Override the package directory                                   |
| `SKIP_CERTS`           | `0`               | `1` installs packages only                                       |

Verbose apt/dpkg output goes to `logs.txt`; the terminal shows only the steps, and
the log tail is printed automatically if a step fails.
