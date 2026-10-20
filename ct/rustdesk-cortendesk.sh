#!/usr/bin/env bash
# Where curl one-liners fetch install/rustdesk-cortendesk-install.sh, the banner and the rdgen payload (raw URL of the
# dir holding ct/, install/ and rdgen/); a fork points this at its own repo. A local checkout always uses its own files.
_CS_DEFAULT_URL="${_CS_DEFAULT_URL:-https://raw.githubusercontent.com/rob-paprocki/rustdesk-cortendesk-pve/stable}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Based on community-scripts ct/rustdeskserver.sh (MIT) by tremor021.
# Copyright (c) 2026 the rustdesk-server-pve contributors
# License: GPL-3.0-or-later (see LICENSE); the community-scripts parts are MIT (see NOTICE)
# Source: https://github.com/marcpope/cortendesk | https://github.com/marcpope/cortendesk-server | https://github.com/bryangerlach/rdgen
#
# Self-hosted RustDesk in one LXC, no Docker: cortendesk-server (hbbs/hbbr with the KeyExchange signed-in
# clients need), the CortenDesk console + API server, and optionally rdgen (custom clients built in your
# own private GitHub repo, pulled back by the LXC; nothing is exposed to the internet).
# Run on the Proxmox host from a checkout that contains ct/, install/ and rdgen/:  bash ct/rustdesk-cortendesk.sh
# Inside the CT: `update` (OS + stack) / `rustdesk-update` (stack; runs daily) / `rustdesk-admin` (console login) /
# `rustdesk-config` (public addresses) / `rustdesk-notify setup` (notifications) / `rdgen-setup` (client builder).

APP="RustDesk-CortenDesk"
_rd_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
# Banner: upstream has none for this app (header_info would print curl 404s), so seed the framework's cache with ours.
_rd_cache="$(declare -f community_scripts_dir >/dev/null 2>&1 && community_scripts_dir || echo /usr/local/community-scripts)/headers/ct/rustdesk-cortendesk"
{ [[ -s "$_rd_cache" || ! -s "$_rd_root/headers/ct/rustdesk-cortendesk" ]] ||
  { mkdir -p "${_rd_cache%/*}" && cp "$_rd_root/headers/ct/rustdesk-cortendesk" "$_rd_cache"; }; } 2>/dev/null || true
var_tags="${var_tags:-remote-desktop}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-16}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
if [[ -z "${var_os:-}" ]] && command -v pveversion >/dev/null 2>&1; then
  var_os=$(msg_menu "Choose the container OS" \
    "alpine" "Alpine 3.24 (smaller footprint)" \
    "debian" "Debian 13")
fi
if [[ "${var_os:-}" == "alpine" ]]; then var_version="${var_version:-3.24}"; else var_version="${var_version:-13}"; fi

header_info "$APP"
variables
color
catch_errors

update_stack() {
  if [[ ! -x /usr/local/bin/rustdesk-update ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating RustDesk server, CortenDesk and rdgen"
  /usr/local/bin/rustdesk-update
  msg_ok "Updated successfully!"
}
update_deb_based() {
  msg_info "Updating OS packages"
  $STD apt-get update
  $STD apt-get -y upgrade
  systemctl restart php8.4-fpm && systemctl reload nginx
  msg_ok "Updated OS packages"
  update_stack
}
update_alpine() {
  msg_info "Updating OS packages"
  $STD apk -U upgrade
  rc-service --quiet php-fpm84 restart && rc-service --quiet nginx reload
  msg_ok "Updated OS packages"
  update_stack
}
function update_script() {
  header_info
  check_container_storage
  check_container_resources
  run_os_update
}

# ------------------------------------------------------------------------------------------------------------------
# Host-side steps after the install. Every failure here must be guarded: an unguarded non-zero exit makes the
# framework's error handler offer to destroy the new container. Secrets go to the CT over stdin, never argv.
BT="Proxmox VE Helper Scripts"
interactive() { [[ "${PHS_SILENT:-0}" != 1 ]] && [[ -t 0 ]] && command -v whiptail >/dev/null; }
wt() { whiptail --backtitle "$BT" "$@" 3>&1 1>&2 2>&3; }   # prints the answer on stdout
ct_run() { pct exec "$CTID" -- "$@"; }

# Console admin: prompt, or var_rd_admin_user / var_rd_admin_pass / var_rd_admin_email; otherwise the generated login stays
admin_skipped() { msg_warn "Console admin not changed: generated login kept in ~/rustdesk-cortendesk.creds (change it with rustdesk-admin in the CT)"; }
setup_console_admin() {
  local user="${var_rd_admin_user:-}" pass="${var_rd_admin_pass:-}" email="${var_rd_admin_email:-}" p2 t="Console admin"
  if [[ -z "$user" || -z "$pass" ]] && interactive; then
    declare -f reclaim_tty >/dev/null 2>&1 && reclaim_tty
    wt --title "$t" --yesno "Set the CortenDesk admin account now?\n\n(No = keep the generated login in ~/rustdesk-cortendesk.creds;\nchange it later with 'rustdesk-admin' inside the CT.)" 12 70 || { admin_skipped; return 0; }
    user=$(wt --title "$t" --inputbox "Admin username (3-64 chars: A-Z a-z 0-9 . _ @ -)" 9 70 "${user:-admin}") || { admin_skipped; return 0; }
    email=$(wt --title "$t" --inputbox "Admin email (optional)" 9 70 "$email") || { admin_skipped; return 0; }
    while :; do
      pass=$(wt --title "$t" --passwordbox "Admin password (min 12 chars; also your rdgen login)" 9 70) || { admin_skipped; return 0; }
      p2=$(wt --title "$t" --passwordbox "Repeat password" 9 70) || { admin_skipped; return 0; }
      [[ "$pass" == "$p2" && ${#pass} -ge 12 ]] && break
      wt --title "$t" --msgbox "Passwords don't match or are shorter than 12 characters." 8 70 || true
    done
  fi
  [[ -n "$user" && -n "$pass" ]] || { admin_skipped; return 0; }
  msg_info "Setting the console admin"
  if printf '%s\n%s\n%s\n' "$user" "$pass" "$email" | ct_run /usr/local/bin/rustdesk-admin --stdin >/dev/null; then
    msg_ok "Console admin set: ${user}"
  else
    msg_error "Could not set the console admin; run 'rustdesk-admin' inside CT ${CTID}"
  fi
}

# Public addresses: var_rd_public_host / var_rd_console_url / var_rd_proxy_ip, or prompts (defaults = the LXC IP)
setup_addresses() {
  local host="${var_rd_public_host:-}" url="${var_rd_console_url:-}" proxy="${var_rd_proxy_ip:-}" t="Addresses"
  if [[ -z "$host" && -z "$url" ]] && interactive; then
    declare -f reclaim_tty >/dev/null 2>&1 && reclaim_tty
    host=$(wt --title "$t" --inputbox "Public host for the ID/relay server: a DNS name (DNS-only, not proxied) or IP that clients reach on ports 21115-21117.\n\nIf it is LAN only for now, keep the LXC IP." 13 74 "${IP}") || host=""
    url=$(wt --title "$t" --inputbox "Console URL: what browsers and the clients' 'API server' setting use,\ne.g. https://rustdesk.example.com (reverse proxy / Cloudflare Tunnel to http://${IP}:80),\nor http://${IP} on the LAN. A public name needs https:// here: clients can't follow\nthe http -> https redirect a proxy sends." 13 74 "http://${IP}") || url=""
    proxy=$(wt --title "$t" --inputbox "Reverse proxy / tunnel connector IP (e.g. your cloudflared LXC).\nNeeded when the console URL is https through a proxy or tunnel on another host, otherwise pages load http:// assets that browsers block. It also makes the logs show real client IPs.\nLeave empty if you have none." 13 74 "") || proxy=""
  fi
  [[ -n "$host" || -n "$url" || -n "$proxy" ]] || return 0
  msg_info "Setting public addresses"
  if printf '%s\n%s\n%s\n' "$host" "$url" "${proxy:-none}" | ct_run /usr/local/bin/rustdesk-config --stdin >/dev/null; then
    msg_ok "Addresses: ID/relay ${host:-unchanged}, console ${url:-unchanged}"
  else
    msg_warn "Could not set the addresses; run 'rustdesk-config' inside CT ${CTID}"
  fi
}

# Notifications (updates, rdgen, CortenDesk's own alerts): var_rd_notify=discord|apprise|apprise-api|none
# + var_rd_notify_url, or prompts
setup_notifications() {
  local method="${var_rd_notify:-}" urls="${var_rd_notify_url:-}" t="Notifications"
  if [[ -z "$method" ]] && interactive; then
    declare -f reclaim_tty >/dev/null 2>&1 && reclaim_tty
    method=$(wt --title "$t" --menu "Where should messages go? Updates (start, success, failure, with versions) and CortenDesk's alerts (approvals, failed logins, security alarms)." 16 74 4 \
      "none" "No notifications (set up later with rustdesk-notify)" \
      "discord" "Discord webhook" \
      "apprise" "Apprise: Discord, Telegram, ntfy, email, 100+ services" \
      "apprise-api" "Existing Apprise API server") || method=none
    case "$method" in
      discord) urls=$(wt --title "$t" --inputbox "Discord webhook URL\n(Server Settings > Integrations > Webhooks > Copy URL)" 10 74) || method=none ;;
      apprise) urls=$(wt --title "$t" --inputbox "Apprise URL(s), separated by spaces\n(e.g. discord://id/token  tgram://bottoken/chatid  ntfys://topic)\nSee https://github.com/caronc/apprise/wiki" 11 74) || method=none ;;
      apprise-api) urls=$(wt --title "$t" --inputbox "Apprise API notify URL (with a config key)\n(e.g. http://apprise.lan:8000/notify/rustdesk)" 10 74) || method=none ;;
    esac
  fi
  [[ -n "$method" && "$method" != none && -n "$urls" ]] || return 0
  local -a list
  read -ra list <<<"$urls"
  msg_info "Setting up notifications (${method})"
  if printf '%s\n' "$method" "${list[@]}" | ct_run /usr/local/bin/rustdesk-notify setup --stdin >/dev/null; then
    msg_ok "Notifications: ${method} (test message sent)"
  else
    msg_warn "Notification setup incomplete; run 'rustdesk-notify setup' inside CT ${CTID}"
  fi
}

# rdgen patches (+ the patch-source helper and GitHub's SSH host keys) -> /usr/local/share/rustdesk-cortendesk/rdgen
# in the CT (too big for the install script)
push_rdgen_payload() {
  local root="${COMMUNITY_SCRIPTS_ROOT:-$_rd_root}" base="${COMMUNITY_SCRIPTS_URL:-$_CS_DEFAULT_URL}" tmp f
  if [[ ! -s "$root/rdgen/patches/UPSTREAM" ]]; then   # remote run: fetch the files listed in MANIFEST
    tmp=$(mktemp -d)
    mkdir -p "$tmp/rdgen/patches"
    curl -fsSL "$base/rdgen/patches/MANIFEST" -o "$tmp/rdgen/patches/MANIFEST" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    while IFS= read -r f; do
      [[ "$f" =~ ^[A-Za-z0-9._-]+$ ]] || continue
      curl -fsSL "$base/rdgen/patches/$f" -o "$tmp/rdgen/patches/$f" || { rm -rf "$tmp"; return 1; }
    done <"$tmp/rdgen/patches/MANIFEST"
    for f in patch-source github_known_hosts; do
      curl -fsSL "$base/rdgen/$f" -o "$tmp/rdgen/$f" || { rm -rf "$tmp"; return 1; }
    done
    chmod 755 "$tmp/rdgen/patch-source"
    root=$tmp
  fi
  # (pct exec may run with umask 077: make the patches world-readable, rdgen-setup applies them as an unprivileged user)
  tar -C "$root" -czf - rdgen/patches rdgen/patch-source rdgen/github_known_hosts | ct_run sh -c 'mkdir -p /usr/local/share/rustdesk-cortendesk && tar -xzf - -C /usr/local/share/rustdesk-cortendesk && chown -R root:root /usr/local/share/rustdesk-cortendesk && chmod -R u=rwX,go=rX /usr/local/share/rustdesk-cortendesk'
  local rc=$?
  [[ -n "${tmp:-}" ]] && rm -rf "$tmp"
  return $rc
}

# rdgen: var_rd_rdgen=yes + var_rd_rdgen_repo / _install_token / _runtime_token / _store_token (yes|no), or prompts
setup_rdgen() {
  local want="${var_rd_rdgen:-}" repo="${var_rd_rdgen_repo:-}" itok="${var_rd_rdgen_install_token:-}"
  local rtok="${var_rd_rdgen_runtime_token:-}" store="${var_rd_rdgen_store_token:-no}" t="rdgen: custom RustDesk clients"
  if ! push_rdgen_payload; then msg_warn "Could not copy the rdgen patches into CT ${CTID}; rdgen-setup will not work"; return 0; fi
  if [[ -z "$want" ]] && interactive; then
    declare -f reclaim_tty >/dev/null 2>&1 && reclaim_tty
    wt --title "$t" --yesno "Set up rdgen now? It builds preconfigured RustDesk clients (Windows, Linux, Android, macOS) in your own private GitHub repo, and this LXC downloads the results. Nothing is exposed to the internet.\n\nYou need:\n - an empty private GitHub repo (e.g. rdgen-build)\n - 2 fine-grained tokens for that repo only:\n     install/update: Contents RW, Workflows RW, Secrets RW\n     runtime: Actions RW\n\nNo = skip (run 'rdgen-setup' in the CT later)." 20 76 || return 0
    want=yes
    repo=$(wt --title "$t" --inputbox "GitHub repository (owner/name)" 9 74 "$repo") || return 0
    itok=$(wt --title "$t" --passwordbox "Install/update token (github_pat_...)\nContents RW, Workflows RW, Secrets RW" 10 74) || return 0
    rtok=$(wt --title "$t" --passwordbox "Runtime token (github_pat_...)\nActions RW" 10 74) || return 0
    if wt --title "$t" --defaultno --yesno "Keep the install token in the CT so rdgen updates itself automatically?\n\nYes = the daily job rebuilds upstream rdgen master with the patches and pushes it to your repo unattended (as an unprivileged user that alone can read the token).\nNo = you get a notification when rdgen has an update; apply it with 'rdgen-update --token-stdin' and a fresh token." 14 76; then store=yes; else store=no; fi
  fi
  [[ "$want" == yes && -n "$repo" && -n "$itok" && -n "$rtok" ]] || return 0
  local log="/root/rdgen-setup-${CTID}.log"
  (umask 077; : >"$log")
  msg_info "Setting up rdgen (build tree, local service, push to ${repo}; takes a few minutes)"
  if printf '%s\n%s\n%s\n%s\n' "$repo" "$itok" "$rtok" "$store" | ct_run /usr/local/bin/rdgen-setup --stdin >>"$log" 2>&1; then
    rm -f "$log"
    msg_ok "rdgen ready: http://${IP}:8190/ (LAN only; same login as the console)"
  else
    msg_warn "rdgen setup incomplete (log on this host: $log); fix and run 'rdgen-setup --github' inside CT ${CTID}"
  fi
}

start
build_container
description
setup_console_admin
setup_addresses
setup_notifications
setup_rdgen

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Console:${CL} ${GATEWAY}${BGN}http://${IP}${CL}"
echo -e "${INFO}${YW}Logins, server key, client settings:${CL} ${BGN}cat ~/rustdesk-cortendesk.creds${CL} (inside the CT)"
echo -e "${INFO}${YW}Router: forward TCP 21115-21117 and UDP 21116 to ${IP}; console via your reverse proxy/tunnel to http://${IP}${CL}"
