# Hardware profile for the Vagrant VM. Hardcoded (not generated) so the flake is
# self-contained and doesn't depend on importing the box's /etc/nixos.
#
# The box (boxen/nixos-25.05) is EFI (OVMF) on a single qcow2/virtual disk with two
# partitions: an ext4 root and a vfat ESP. Neither has a filesystem LABEL, so we
# reference them by UUID (works the same on libvirt /dev/vda and VirtualBox /dev/sda).
# These UUIDs come from the box's base image and are stable for this box_version; if
# you bump the box, re-read them from the powered-off disk with:
#   sudo qemu-nbd -r -c /dev/nbd0 <image.img> && sudo blkid /dev/nbd0p1 /dev/nbd0p2
# (root = the ext4 partition, /boot = the vfat ESP).
{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # EFI via systemd-boot. canTouchEfiVariables = false because Vagrant supplies
  # the NVRAM (efivars.fd); systemd-boot still installs the removable-media
  # fallback (\EFI\BOOT\BOOTX64.EFI), so the VM boots without NVRAM entries.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # Superset covering libvirt (virtio) and VirtualBox (SATA/AHCI/USB) disks.
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "ehci_pci"
    "ahci"
    "xhci_pci"
    "nvme"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/0502c5ed-7419-449c-b382-78b9e41dccf4";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/4E11-1575";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];
}
