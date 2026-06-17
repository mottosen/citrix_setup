# Citrix `.deb` packages go here

The Citrix Workspace App packages are **not** committed to this repo (they are
large and licensed). Download them manually and drop them in this directory
before running `../install_citrix.sh`.

## What you need

Two packages for **Debian / Ubuntu (x86_64)**:

| File                            | Listed on the page as                                   |
| ------------------------------- | ------------------------------------------------------- |
| `icaclient_<version>_amd64.deb` | _Full Package (Self-Service Support)_ — Debian, ~430 MB |
| `ctxusb_<version>_amd64.deb`    | _USB Support Package_ — Debian, ~150 KB                 |

`install_citrix.sh` automatically picks the newest `icaclient_*.deb` and
`ctxusb_*.deb` found here, so you can keep multiple versions if you like.

## Where to download

1. Open the official "Workspace app for Linux (latest)" page:
   <https://www.citrix.com/downloads/workspace-app/linux/workspace-app-for-linux-latest.html>
2. Accept the EULA when prompted.
3. Under **Debian Packages**, download:
   - **Full Package (Self-Service Support)** → `icaclient_*_amd64.deb`
   - **USB Support Package** → `ctxusb_*_amd64.deb`
4. Move both files into this `deb_files/` directory.

> The download links are generated per-session after you accept the license, so
> they can't be scripted — this manual step is unavoidable.

After placing the files here:

```bash
cd ..
./install_citrix.sh
```
