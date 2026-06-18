# Citrix Workspace downloads (shared by both VMs)

Both setups need Citrix's Linux client, just in different forms — the **Ubuntu**
VM installs `.deb` packages, the **NixOS** VM builds from the `.tar.gz` tarball.
They're all artifacts of the same Citrix release, so download them **once** on
the host and drop them here; both VMs read this one directory.

Nothing in here is committed (the files are large and licensed — they're
git-ignored). Get them from the official page, accepting the EULA:
<https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html>
(or <https://www.citrix.com/downloads/workspace-app/> for older versions).

## For the Ubuntu VM — Debian packages

| File                            | Listed on the page as                                   |
| ------------------------------- | ------------------------------------------------------- |
| `icaclient_<version>_amd64.deb` | _Full Package (Self-Service Support)_ — Debian, ~430 MB |
| `ctxusb_<version>_amd64.deb`    | _USB Support Package_ — Debian, ~150 KB                 |

`ubuntu/install_citrix.sh` auto-picks the newest `icaclient_*.deb` and
`ctxusb_*.deb` here (override the dir with `DEB_DIR=`).

## For the NixOS VM — tarball

The **64-bit Tarball Package**, matching the version nixpkgs pins (currently
**`linuxx64-26.01.0.150.tar.gz`** on nixos-26.05). Under **Tarball Packages** on
the same page, download the x86_64 `linuxx64-<version>.tar.gz`.

The version **must match** what the flake's nixpkgs expects, or the `requireFile`
hash won't match. If you can only get a different one, override the source in
`../nixos/flake.nix` (`citrix_workspace.override { src = ...; }`) or pin nixpkgs.

> Download links are generated per-session after you accept the license, so they
> can't be scripted — this manual step is unavoidable. The NixOS Vagrant
> provisioner registers the tarball found here into the Nix store automatically.
