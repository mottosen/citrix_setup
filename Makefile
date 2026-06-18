# Citrix VM bring-up. Run from a `nix develop` shell (it provides vagrant, make,
# rsync). Get started with just:  nix develop ; make nixos
#
#   make nixos                  provision the NixOS VM, then halt it
#   make ubuntu                 provision the Ubuntu VM, then halt it
#   make nixos PROVIDER=libvirt choose a provider (default: your vagrant default)
#   make nixos-certs            re-run the cert step on an existing NixOS VM
#   make ubuntu-certs           re-run the install/cert step on an existing Ubuntu VM
#   make nixos-destroy / ubuntu-destroy
#
# `make <vm>` prompts for the gateway hostname (saved to ./.citrix-host, shared by
# both VMs), runs
# `vagrant up` (which provisions), then `vagrant halt`. It deliberately leaves the
# VM OFF: App Protection only activates on a clean boot, so you start the VM
# yourself afterwards — which is that clean boot:
#
#     cd nixos && vagrant up      # then open the display (virt-manager / VirtualBox)

PROVIDER_ARG = $(if $(PROVIDER),--provider=$(PROVIDER))

.PHONY: nixos ubuntu nixos-certs ubuntu-certs nixos-destroy ubuntu-destroy

# $(1) = subdir (nixos | ubuntu). Prompt for host, provision, then halt.
define provision_and_halt
	@host="$$CITRIX_HOST"; \
	if [ -n "$$host" ]; then \
		echo "Using gateway host '$$host' (from \$$CITRIX_HOST)."; \
	elif [ -f .citrix-host ]; then \
		host="$$(head -n1 .citrix-host | tr -d '[:space:]')"; \
		echo "Using saved gateway host '$$host' (from ./.citrix-host — 'rm .citrix-host' to change)."; \
	fi; \
	if [ -z "$$host" ]; then \
		printf 'Citrix gateway hostname (e.g. vdi.example.com): '; read -r host; \
		host="$$(printf '%s' "$$host" | tr -d '[:space:]')"; \
		[ -n "$$host" ] || { echo "no hostname entered" >&2; exit 1; }; \
		printf 'Remember it in ./.citrix-host (git-ignored, shared by both VMs)? [Y/n] '; read -r ans; \
		case "$$ans" in [Nn]*) : ;; *) printf '%s\n' "$$host" > .citrix-host;; esac; \
	fi; \
	echo "==> Provisioning the $(1) VM for $$host ..."; \
	cd $(1) && CITRIX_HOST="$$host" vagrant up $(PROVIDER_ARG) && { \
		echo "==> Done. Halting so your next start is a clean boot (App Protection needs it):"; \
		echo "      cd $(1) && vagrant up      # then open the display"; \
		vagrant halt; \
	}
endef

nixos:
	$(call provision_and_halt,nixos)

ubuntu:
	$(call provision_and_halt,ubuntu)

nixos-certs:
	cd nixos && vagrant provision --provision-with certs

ubuntu-certs:
	cd ubuntu && vagrant provision --provision-with citrix

nixos-destroy:
	cd nixos && vagrant destroy -f

ubuntu-destroy:
	cd ubuntu && vagrant destroy -f
