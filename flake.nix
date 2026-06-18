{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        vagrant = pkgs.vagrant.override { withLibvirt = true; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            vagrant
            pkgs.libvirt
            pkgs.qemu
            pkgs.openssh
            pkgs.gnumake # `make nixos` / `make ubuntu`
            pkgs.rsync # host side of the VMs' rsync synced folders
          ];

          shellHook = ''
            export PATH="${pkgs.openssh}/libexec:$PATH"
            vagrant plugin list 2>/dev/null | grep -q vagrant-sshfs || \
              vagrant plugin install vagrant-sshfs
            clear
            echo "Flake ready for use!"
          '';
        };
      }
    );
}
