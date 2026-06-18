# Citrix Workspace App setup

Helpers to run the Citrix Workspace client in a Linux VM with the gateway's CA
chain trusted by the client's own keystore (fixing **"SSL error 61"**). Pick
either VM — they're interchangeable: **`ubuntu/`** (apt + `.deb`) or **`nixos/`**
(declarative flake).

## Prerequisites

- **Nix** (with flakes) — everything runs from `nix develop`, which provides
  `vagrant`, `make` and `rsync`.
- A **Vagrant provider**: libvirt (`vagrant-libvirt`) or VirtualBox.
- The **Citrix downloads** in [`citrix_files/`](citrix_files/README.md) — fetched
  once on the host and shared by both VMs.

## Getting started

```bash
nix develop          # dev shell with vagrant, make, rsync
make ubuntu          # or: make nixos
```

`make <vm>` prompts for the gateway hostname (saved to `./.citrix-host`, shared by
both VMs), provisions the VM, then **halts** it. Start it yourself for a clean
boot — App Protection needs one:

```bash
cd ubuntu && vagrant up      # then open the display (virt-manager / VirtualBox)
```

Other targets: `make ubuntu-certs` / `make nixos-certs` (re-run the cert step),
`make ubuntu-destroy` / `make nixos-destroy`, `make <vm> PROVIDER=libvirt` (pick a
provider). Details in [`ubuntu/README.md`](ubuntu/README.md) and
[`nixos/README.md`](nixos/README.md).

## Layout

| Path            | What it is                                                                     |
| --------------- | ------------------------------------------------------------------------------ |
| `ubuntu/`       | Ubuntu 24.04 VM (apt + `.deb`), provisioned by Vagrant.                        |
| `nixos/`        | Declarative NixOS VM via Vagrant + flakes (`citrix_workspace` + `extraCerts`). |
| `shared/`       | OS-agnostic cert tooling used by both: `ensure_certificates.sh`, `common.sh`.  |
| `citrix_files/` | Host-side Citrix downloads (`.deb` + `.tar.gz`), shared by both VMs.           |

## How the certificates work

The Citrix client uses its **own** keystore (`keystore/cacerts`), not the
system/browser trust store, and won't auto-fetch missing intermediates — hence
**SSL error 61** when it doesn't trust the gateway's CA chain.

The **generation** (fetch the gateway chain, complete it, stage the CA certs as
PEMs) lives in `shared/ensure_certificates.sh` and is reused by both VMs. They
differ only in how the staged certs are _consumed_: Ubuntu copies them into the
keystore at install time; NixOS feeds them to `extraCerts` so they're baked in at
build time. The chain is staged **inside the guest** and never committed — a
corporate CA can disclose internal PKI, and this is a public repo.
