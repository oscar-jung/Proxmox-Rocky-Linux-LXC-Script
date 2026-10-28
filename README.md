# Rocky Linux LXC for Proxmox VE

Interactive installer in the style of [community-scripts](https://github.com/community-scripts/ProxmoxVE),
using the newest Rocky Linux template available from `pveam`.

## Install

Run in the Proxmox VE host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oscar-jung/Proxmox-Rocky-Linux-LXC-Script/main/ct/rockylinux.sh)"
```

Pin a major version with `var_version=9 bash -c "$(curl ...)"`.

Inside the container, run `update` to upgrade packages.

## Non-interactive

`create-rocky-lxc.sh` creates the same container from command-line options. See `./create-rocky-lxc.sh --help`.
