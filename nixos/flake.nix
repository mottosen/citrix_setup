{
  description = "Minimal NixOS VM running Citrix Workspace, provisioned via Vagrant + flakes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    {
      nixosConfigurations.dev-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          (
            { pkgs, lib, ... }:
            let
              # ---- impure, VM-local gateway CA chain ---------------------------
              # ../shared/ensure_certificates.sh (run inside the guest) stages the
              # gateway's CA chain into this fixed runtime path. The PEMs are NOT
              # committed: a corporate internal CA can disclose employer/internal
              # PKI details, and this is a public repo. So the flake reads them
              # from outside its own source tree — the ONLY impurity here, hence
              # builds must use `nixos-rebuild --impure`. Everything else is pure.
              #
              # The path is empty on first boot (-> no extra certs); re-run the
              # cert script + rebuild once the gateway is reachable to populate it.
              stagingDir = /var/lib/citrix-certs/staged;
              stagedCerts =
                if builtins.pathExists stagingDir then
                  map (name: stagingDir + "/${name}") (
                    builtins.filter (lib.hasSuffix ".pem") (builtins.attrNames (builtins.readDir stagingDir))
                  )
                else
                  [ ];

              # citrix_workspace copies each extraCert into keystore/cacerts and
              # runs ctx_rehash at build time — the declarative equivalent of the
              # Ubuntu install_citrix.sh cert step, and the fix for "SSL error 61".
              #
              # App Protection (anti-keylogging / anti-screen-capture), the
              # APP_PROTECTION=yes default in the Ubuntu installer: the upstream
              # `hinst` defaults this prompt to "no", and nixpkgs rewrites the
              # installer's answer to "$INSTALLER_YES" but never defines that var.
              # Setting it to "yes" makes the build install the App Protection
              # component (deviceTrust/EPA/fido2 stay off — stripped separately).
              # EXPERIMENTAL on NixOS: also needs the GNOME/GDM session above and
              # a reboot to activate; see README.
              citrix = (pkgs.citrix_workspace.override { extraCerts = stagedCerts; }).overrideAttrs (_: {
                INSTALLER_YES = "yes";
              });

              # Combined CA bundle for AuthManager/curl: the public roots PLUS the
              # staged gateway chain (crucially the INTERMEDIATE the gateway omits).
              # NixOS's own ca-certificates.crt only contains root anchors, so an
              # intermediate added via security.pki.certificateFiles never lands in
              # that file — curl then can't build the chain. We instead concatenate
              # cacert's bundle with the staged PEMs and point SSL_CERT_FILE /
              # CURL_CA_BUNDLE at the result (below). Interpolating each staged path
              # imports it into the store (impure, like extraCerts).
              citrixCaBundle = pkgs.runCommand "citrix-ca-bundle.crt" { } (
                ''
                  cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt > $out
                ''
                + lib.concatMapStrings (c: ''
                  cat ${c} >> $out
                '') stagedCerts
              );
            in
            {
              # Root filesystem + bootloader for the VM. A `--flake` rebuild
              # ignores the box's /etc/nixos, so this must be defined here or the
              # build fails the "no root filesystem" / "no bootloader" assertions.
              imports = [ ./hardware-configuration.nix ];

              networking.hostName = "citrix-vm";

              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];

              # citrix_workspace is unfree — allow just that one package.
              nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "citrix-workspace" ];

              # citrix_workspace still links the EOL libsoup 2.x; permit it so the
              # build isn't blocked on the insecure-package check.
              nixpkgs.config.permittedInsecurePackages = [ "libsoup-2.74.3" ];

              # Citrix has TWO independent trust paths. extraCerts (above) fixes the
              # ICA-SSL engine's keystore ("SSL error 61", wfica). But AuthManager /
              # self-service speak HTTPS to StoreFront (…/pnagent/config.xml) via
              # libcurl/OpenSSL, which (a) need to be TOLD where the CA bundle is and
              # (b) need that bundle to contain the gateway's intermediate. NixOS's
              # ca-certificates.crt holds only root anchors, and SSL_CERT_FILE isn't
              # otherwise set for these processes — so point both env vars at our
              # explicit combined bundle (roots + staged chain incl. the intermediate).
              # Without this, auth fails with curl error 60 and the client hangs on
              # "connecting". sessionVariables so the GDM/GNOME session + the Citrix
              # processes it spawns inherit them via PAM.
              environment.sessionVariables = {
                SSL_CERT_FILE = "${citrixCaBundle}";
                CURL_CA_BUNDLE = "${citrixCaBundle}";
                # The VM has no GPU, so Mesa defaults to the ZINK (GL-on-Vulkan) path
                # and fails ("ZINK: failed to choose pdev" / no dri2 screen). wfica's
                # session renderer then dies and the desktop launch reports "not
                # available". Force software (llvmpipe) GL so the HDX session renders.
                LIBGL_ALWAYS_SOFTWARE = "1";
                GALLIUM_DRIVER = "llvmpipe";
              };
              # sessionVariables only reliably reaches login SHELLS (/etc/profile).
              # The GDM/GNOME graphical session — and the Citrix daemons it spawns —
              # get their environment from the systemd USER manager, which reads
              # /etc/environment.d/*.conf, NOT /etc/profile. Without this, AuthManager
              # launches with an empty SSL_CERT_FILE and the login hangs even though a
              # login shell trusts the gateway fine. (Reboot applies it.)
              environment.etc."environment.d/10-citrix-ca.conf".text = ''
                SSL_CERT_FILE=${citrixCaBundle}
                CURL_CA_BUNDLE=${citrixCaBundle}
                LIBGL_ALWAYS_SOFTWARE=1
                GALLIUM_DRIVER=llvmpipe
              '';

              # Keep the box manageable by Vagrant once our config replaces the
              # box's own. Pin the vagrant user/group to uid/gid 1000 (what the
              # box uses) and its own primary group — otherwise NixOS defaults the
              # group to "users", deletes the "vagrant" group, and the broken
              # session drops Vagrant's SSH mid-provision. The insecure key is a
              # fallback; Vagrant's generated key in ~/.ssh keeps working too.
              users.groups.vagrant.gid = 1000;
              users.users.vagrant = {
                isNormalUser = true;
                uid = 1000;
                group = "vagrant";
                extraGroups = [ "wheel" ];
                initialPassword = "vagrant";
                openssh.authorizedKeys.keys = [
                  "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key"
                ];
              };
              security.sudo.wheelNeedsPassword = false;

              services.openssh.enable = true;

              # ---- graphical session (GNOME + GDM, Xorg) -----------------------
              # App Protection on Linux REQUIRES a GNOME desktop + GDM (Citrix
              # system requirement). GNOME 50 (on 26.05) is Wayland-only, so the
              # Citrix client runs via XWayland; App Protection's requirement is
              # GDM + GNOME, both satisfied here. Autologin as vagrant.
              # (Heavier than the previous XFCE setup, but mandated by the layer.)
              services.xserver.enable = true;
              services.desktopManager.gnome.enable = true;
              services.displayManager.gdm.enable = true;
              services.displayManager.autoLogin = {
                enable = true;
                user = "vagrant";
              };
              services.displayManager.defaultSession = "gnome";

              # SPICE/QEMU guest agents: clipboard + automatic resolution resize
              # when the VM is viewed through virt-manager (libvirt/SPICE).
              services.spice-vdagentd.enable = true;
              services.qemuGuest.enable = true;

              # Host<->guest clipboard. spice-vdagentd (above) talks to the host over
              # the virtio channel, but the per-session `spice-vdagent` client is an
              # X11 app: under GNOME-Wayland it must target XWayland (:0), and it has
              # to be running BEFORE the SPICE viewer connects or the clipboard never
              # negotiates. nixpkgs' autostart .desktop launches it with no fixed
              # DISPLAY, so it exits with "could not connect to X-server" and nothing
              # runs. Pin it to :0 as a user service tied to the graphical session.
              systemd.user.services.spice-vdagent = {
                description = "SPICE vdagent (host/guest clipboard) on XWayland";
                after = [ "graphical-session.target" ];
                partOf = [ "graphical-session.target" ];
                wantedBy = [ "graphical-session.target" ];
                environment.DISPLAY = ":0";
                serviceConfig = {
                  ExecStart = "${pkgs.spice-vdagent}/bin/spice-vdagent -x";
                  Restart = "on-failure";
                  RestartSec = 2;
                };
              };

              environment.systemPackages = with pkgs; [
                citrix
                # tools ensure_certificates.sh relies on, plus git so `path:`
                # flake builds work against the synced /vagrant tree.
                openssl
                gawk
                curl
                cacert
                git
                # wl-clipboard: lets us inject text into the guest clipboard from an
                # SSH session (wl-copy) as a fallback when SPICE clipboard misbehaves.
                wl-clipboard
                # Citrix's own embedded logon browser doesn't render on this stripped
                # NixOS GNOME. Use a real browser for the NetScaler web logon instead:
                # sign in at the StoreWeb, launch an app -> it downloads a .ica that the
                # local wfica engine opens (its keystore SSL trust is already fixed).
                firefox
              ];

              system.stateVersion = "26.05";
            }
          )
        ];
      };
    };
}
