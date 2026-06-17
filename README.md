# Citrix Workspace App setup (Linux VM)

Scripts to install, certificate-fix, and cleanly uninstall the Citrix Workspace
App / ICA client inside an Ubuntu VM. They solve the common case where the
**browser logs in fine but the Citrix client fails with "SSL error 61"** — the
client uses its own certificate keystore (`/opt/Citrix/ICAClient/keystore/cacerts`),
not the system/browser trust store, and it won't auto-fetch missing intermediates.

## Prerequisites

- **Ubuntu 24.04 (Noble)** — the expected/tested release. Other versions may
  need a different WebKit runtime package (the install pulls
  `libwebkit2gtk-4.1-0`, which is the 24.04 name).
- Tools: `openssl`, `awk`, and `curl` or `wget`.
- The Citrix `.deb` packages in `deb_files/` (an `icaclient_*.deb` and a
  `ctxusb_*.deb`). These are **not** committed (large + licensed); download them
  manually — see [`deb_files/README.md`](deb_files/README.md).

## Usage

```bash
# 1. Fetch & stage the gateway's certificate chain (prompts for the hostname)
./ensure_certificates.sh

# 2. Install Citrix (from deb_files/) and wire the certs into the keystore
./install_citrix.sh

# 3. Remove everything (e.g. to retry / reinstall)
./uninstall_citrix.sh
```

`install_citrix.sh` auto-runs step 1 if no certs are staged yet. Verbose
apt/dpkg output is written to `logs.txt`; the terminal shows only the steps,
and the log tail is printed automatically if a step fails.

### Options (environment variables)

| Var                    | Default      | Meaning                                                          |
| ---------------------- | ------------ | ---------------------------------------------------------------- |
| `CITRIX_HOST`          | _(prompted)_ | Gateway hostname; skips the prompt when set                      |
| `APP_PROTECTION`       | `yes`        | App Protection component (required by the VDI; **irreversible**) |
| `DEVICE_TRUST` / `EPA` | `no`         | Optional deviceTRUST / Endpoint Analysis components              |
| `INTERACTIVE`          | `0`          | `1` restores the package's own install prompts                   |
| `DEB_DIR`              | `deb_files`  | Override the package directory                                   |
| `SKIP_CERTS`           | `0`          | `1` installs packages only                                       |

`./uninstall_citrix.sh --deps` also removes the generic GUI runtime libraries
the installer pulled in (normally left in place, as other apps may use them).

## Mounting the host share (virtiofs)

Handy commands when this repo is shared into the VM via virtiofs (adjust the
`host_citrix` tag / mountpoint to your setup):

```bash
# create mountpoint
sudo mkdir -p /mnt/host_shared

# mount
sudo mount -t virtiofs host_citrix /mnt/host_shared

# unmount
sudo umount /mnt/host_shared
```
