#!/usr/bin/env bash
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Based on community-scripts ProxmoxVE ct/debian.sh and ct/rockylinux.sh
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://rockylinux.org/
#
# Same interactive installer as the community scripts (whiptail menus,
# Default/Advanced settings, console autologin), except the Rocky Linux
# version is not pinned: it is the newest major version `pveam` offers.
# Pin one with: var_version=9 bash rockylinux.sh

# Newest rockylinux-<major>-default template in the host's pveam catalog.
# Prints nothing off a PVE host (e.g. when `update` runs inside the CT).
latest_rocky_version() {
  command -v pveam >/dev/null 2>&1 || return 0
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  timeout 30 pveam update >/dev/null 2>&1 || true
  pveam available --section system 2>/dev/null |
    awk '{print $2}' |
    sed -nE "s/^rockylinux-([0-9]+)-default_.*_${arch}\.tar\.(xz|zst|gz)$/\1/p" |
    sort -V | tail -n1
}

APP="Rocky Linux"
var_tags="${var_tags:-os}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
var_os="${var_os:-rockylinux}"
var_version="${var_version:-$(latest_rocky_version)}"
var_version="${var_version:-10}" # catalog unreachable: fall back to upstream's default
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /var ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating Rocky Linux LXC"
  $STD dnf -y upgrade
  msg_ok "Updated Rocky Linux LXC"
  msg_ok "Completed successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
msg_custom "🚀" "${GN}" "${APP} ${var_version} setup has been successfully initialized!"
