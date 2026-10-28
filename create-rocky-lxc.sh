#!/usr/bin/env bash
# Create a Rocky Linux LXC on Proxmox VE from the newest template pveam offers.
# Like the community-scripts Debian LXC: no root password, console autologin.
#
# Run as root on the Proxmox host:  ./create-rocky-lxc.sh [options]
# Every option can also be given as an environment variable (see defaults).
set -Eeuo pipefail

# ---- defaults ---------------------------------------------------------------
CTID="${CTID:-}"                          # empty = next free ID
CT_HOSTNAME="${CT_HOSTNAME:-rocky}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"                  # MiB
SWAP="${SWAP:-512}"                       # MiB
DISK_SIZE="${DISK_SIZE:-8}"               # GiB
STORAGE="${STORAGE:-local-lvm}"           # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                          # dhcp or CIDR, e.g. 192.168.1.50/24
GATEWAY="${GATEWAY:-}"
VLAN="${VLAN:-}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
PASSWORD="${PASSWORD:-}"                  # set one to disable autologin
SSH_KEY_FILE="${SSH_KEY_FILE:-}"          # public key file for root
TIMEZONE="${TIMEZONE:-host}"
ROCKY_VERSION="${ROCKY_VERSION:-}"        # empty = newest major version
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
TAGS="${TAGS:-rocky}"
ONBOOT="${ONBOOT:-1}"
AS_TEMPLATE="${AS_TEMPLATE:-0}"           # 1 = convert to a PVE template at the end

BASE_PACKAGES="wget vim-enhanced nano bash-completion openssh-server sudo tar less iproute iputils"

# ---- helpers ----------------------------------------------------------------
msg()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m ok\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m !!\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31merr\e[0m %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Usage: $0 [options]

  --ctid ID             container ID (default: next free)
  --hostname NAME       hostname (default: $CT_HOSTNAME)
  --cores N             CPU cores (default: $CORES)
  --memory MiB          RAM (default: $MEMORY)
  --swap MiB            swap (default: $SWAP)
  --disk GiB            rootfs size (default: $DISK_SIZE)
  --storage NAME        rootfs storage (default: $STORAGE)
  --template-storage N  where templates live (default: $TEMPLATE_STORAGE)
  --bridge NAME         network bridge (default: $BRIDGE)
  --ip CIDR|dhcp        IPv4 address (default: $IP)
  --gateway IP          IPv4 gateway (needed with a static IP)
  --vlan TAG            VLAN tag
  --privileged          make a privileged container
  --password PW         set a root password (disables console autologin)
  --ssh-key FILE        authorized public key for root
  --timezone TZ         timezone or "host" (default: $TIMEZONE)
  --version N           Rocky major version (default: newest available)
  --packages "a b c"    extra dnf packages to install
  --tags "a;b"          PVE tags (default: $TAGS)
  --no-onboot           don't start on host boot
  --as-template         clean up and convert to a PVE template when done
  -h, --help            show this help
EOF
}

# ---- arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  opt="$1"
  case "$opt" in
    --privileged)  UNPRIVILEGED=0; shift; continue ;;
    --no-onboot)   ONBOOT=0; shift; continue ;;
    --as-template) AS_TEMPLATE=1; shift; continue ;;
    -h|--help)     usage; exit 0 ;;
  esac
  [[ $# -ge 2 ]] || die "$opt needs a value (see --help)"
  case "$opt" in
    --ctid)             CTID="$2" ;;
    --hostname)         CT_HOSTNAME="$2" ;;
    --cores)            CORES="$2" ;;
    --memory)           MEMORY="$2" ;;
    --swap)             SWAP="$2" ;;
    --disk)             DISK_SIZE="$2" ;;
    --storage)          STORAGE="$2" ;;
    --template-storage) TEMPLATE_STORAGE="$2" ;;
    --bridge)           BRIDGE="$2" ;;
    --ip)               IP="$2" ;;
    --gateway)          GATEWAY="$2" ;;
    --vlan)             VLAN="$2" ;;
    --password)         PASSWORD="$2" ;;
    --ssh-key)          SSH_KEY_FILE="$2" ;;
    --timezone)         TIMEZONE="$2" ;;
    --version)          ROCKY_VERSION="$2" ;;
    --packages)         EXTRA_PACKAGES="$2" ;;
    --tags)             TAGS="$2" ;;
    *)                  die "unknown option: $opt (see --help)" ;;
  esac
  shift 2
done

# ---- pre-flight -------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null \
  || die "pct/pveam not found - is this a Proxmox VE host?"
if [[ -n "$SSH_KEY_FILE" && ! -r "$SSH_KEY_FILE" ]]; then
  die "cannot read SSH key file: $SSH_KEY_FILE"
fi
if [[ "$IP" != dhcp && -z "$GATEWAY" ]]; then
  warn "static IP without --gateway: the container may have no internet access"
fi

if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid)"
elif ! pvesh get /cluster/nextid --vmid "$CTID" &>/dev/null; then
  die "ID $CTID is already in use"
fi

# ---- template ---------------------------------------------------------------
msg "Looking up the newest Rocky Linux template"
pveam update >/dev/null || warn "pveam update failed, using the cached template list"
TEMPLATE="$(pveam available --section system | awk '{print $2}' \
  | grep -E "^rockylinux-${ROCKY_VERSION:-[0-9]+}-default_.*_amd64\.tar\.(xz|zst|gz)$" \
  | sort -V | tail -n1 || true)"
[[ -n "$TEMPLATE" ]] || die "no Rocky Linux ${ROCKY_VERSION} template found in 'pveam available'"
ok "template: $TEMPLATE"

if ! pveam list "$TEMPLATE_STORAGE" \
     | awk -v t="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" '$1 == t {f = 1} END {exit !f}'; then
  msg "Downloading $TEMPLATE to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ---- create -----------------------------------------------------------------
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
if [[ -n "$GATEWAY" ]]; then NET+=",gw=$GATEWAY"; fi
if [[ -n "$VLAN" ]]; then NET+=",tag=$VLAN"; fi

args=(
  --hostname "$CT_HOSTNAME"
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP"
  --rootfs "$STORAGE:$DISK_SIZE"
  --net0 "$NET"
  --unprivileged "$UNPRIVILEGED"
  --features nesting=1
  --onboot "$ONBOOT"
  --timezone "$TIMEZONE"
  --tags "$TAGS"
)
if [[ -n "$PASSWORD" ]]; then args+=(--password "$PASSWORD"); fi
if [[ -n "$SSH_KEY_FILE" ]]; then args+=(--ssh-public-keys "$SSH_KEY_FILE"); fi

msg "Creating CT $CTID ($CT_HOSTNAME)"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" "${args[@]}"
pct start "$CTID"

msg "Waiting for network inside the container"
for i in {1..30}; do
  if pct exec "$CTID" -- getent hosts dl.rockylinux.org &>/dev/null; then break; fi
  if [[ $i -eq 30 ]]; then die "no network/DNS inside CT $CTID after 60s"; fi
  sleep 2
done
ok "network is up"

# ---- provision --------------------------------------------------------------
msg "Updating packages"
pct exec "$CTID" -- dnf -y upgrade
msg "Installing packages"
# shellcheck disable=SC2086  # package lists are meant to be word-split
pct exec "$CTID" -- dnf -y install $BASE_PACKAGES $EXTRA_PACKAGES
pct exec "$CTID" -- systemctl enable --now sshd
pct exec "$CTID" -- dnf clean all >/dev/null

if [[ -z "$PASSWORD" ]]; then
  msg "Enabling root autologin on the console"
  AUTOLOGIN_SCRIPT='
set -e
d=/etc/systemd/system/container-getty@1.service.d
mkdir -p "$d"
cat > "$d/override.conf" <<"EOF"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF
systemctl daemon-reload
systemctl restart container-getty@1.service
'
  pct exec "$CTID" -- bash -c "$AUTOLOGIN_SCRIPT"
fi

# ---- optional: turn into a template -----------------------------------------
if [[ "$AS_TEMPLATE" == 1 ]]; then
  msg "Cleaning up and converting CT $CTID to a template"
  # Clones get fresh SSH host keys and machine-id on first boot.
  pct exec "$CTID" -- bash -c 'rm -f /etc/ssh/ssh_host_* && truncate -s 0 /etc/machine-id'
  pct shutdown "$CTID"
  pct template "$CTID"
  ok "template $CTID ready - clone it with: pct clone $CTID <newid> --hostname <name> --full"
  exit 0
fi

# ---- done -------------------------------------------------------------------
ADDR="$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 | awk '{print $4}' || true)"
ok "CT $CTID ($CT_HOSTNAME) is ready"
echo "    IP:      ${ADDR:-unknown}"
echo "    Release: $(pct exec "$CTID" -- cat /etc/rocky-release 2>/dev/null || echo unknown)"
echo "    Console: PVE web UI > $CTID > Console (autologin: $([[ -z "$PASSWORD" ]] && echo on || echo off))"
echo "    Shell:   pct enter $CTID"
