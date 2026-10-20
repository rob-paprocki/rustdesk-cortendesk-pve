# shellcheck shell=bash
# Shared helpers for the rustdesk-cortendesk tools (sourced, not executed).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022   # predictable modes whatever the caller had; secrets are written with explicit 0600/0640
# crond / systemd timers do not read the proxy the framework persisted for login shells
if [ -r /etc/profile.d/90-http-proxy.sh ]; then set -a; . /etc/profile.d/90-http-proxy.sh; set +a; fi

if [ -f /etc/alpine-release ]; then
  OS=alpine PHP=/usr/bin/php84 FPM=php-fpm84 WEBUSER=nginx
else
  OS=debian PHP=/usr/bin/php8.4 FPM=php8.4-fpm WEBUSER=www-data
fi
CD_APP=/opt/cortendesk CD_DATA=/var/lib/cortendesk CD_ETC=/etc/cortendesk
CD_ENV=$CD_ETC/cortendesk.env CD_DB=$CD_DATA/cortendesk.sqlite
SRV_BIN=/opt/rustdesk-server SRV_DATA=/var/lib/rustdesk-server SRV_CONF=/etc/rustdesk-server/hbbs.conf
RDGEN_APP=/opt/rdgen RDGEN_ENV=/etc/rdgen/rdgen.env RDGEN_DATA=/var/lib/rdgen
# the GitHub build side runs as its own user (never root): it executes upstream rdgen code during checks
RDGEN_BUILD=/var/lib/rdgen-build RDGEN_SRC=/var/lib/rdgen-build/src
RDGEN_STATE=/var/lib/rdgen-build/bootstrap.json RDGEN_TOKEN=/var/lib/rdgen-build/install.token
RDGEN_PATCHES=/usr/local/share/rustdesk-cortendesk/rdgen/patches
BK=/var/backups/rustdesk
UPDATE_ENV=/etc/rustdesk-update.env
CREDS=/root/rustdesk-cortendesk.creds
CURL=(curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 15)

svc() {  # svc <start|stop|restart|reload> <name>; fd 9 (the updater lock) must not leak into daemons
  if command -v systemctl >/dev/null; then systemctl "$1" "$2" 9>&-; else rc-service --quiet "$2" "$1" 9>&-; fi
}
as_user() {  # as_user <user> <cmd...>: run as a service user (its primary group); secrets go via stdin, not argv
  # fd 9 (the updater lock) is closed: a service user's process must never keep holding it
  local u=$1 g; shift; g=$(id -gn "$u")
  if command -v su-exec >/dev/null; then su-exec "$u:$g" "$@" 9>&-; else runuser -u "$u" -g "$g" -- "$@" 9>&-; fi
}
update_lock() {  # update_lock: open /run/rustdesk-update.lock as fd 9, root-only (any user may flock a readable file)
  (umask 077; : >>/run/rustdesk-update.lock) && chmod 600 /run/rustdesk-update.lock && exec 9>/run/rustdesk-update.lock
}
update_lock_wait() {  # update_lock_wait <seconds>: take the lock on fd 9, waiting up to <seconds> (busybox flock has no -w)
  local n=0
  update_lock
  until flock -n 9; do
    n=$((n + 5)); [ "$n" -le "$1" ] || return 1
    sleep 5
  done
}
as_build() {  # GitHub build side of rdgen; explicit git identity (service users have no GECOS name)
  as_user rdgenbuild env HOME="$RDGEN_BUILD" GIT_AUTHOR_NAME=rdgen-build GIT_AUTHOR_EMAIL=rdgen-build@localhost \
    GIT_COMMITTER_NAME=rdgen-build GIT_COMMITTER_EMAIL=rdgen-build@localhost "$@"
}
# write_as <user> <dest> [mode]: write stdin to <dest> AS <user> (default mode 0600), via a temp file + rename
# in the same dir. Root must never create/chmod/chown paths inside a service-owned directory (the owner can
# swap them for symlinks); root only opens the source stream.
write_as() {
  as_user "$1" sh -c 't=$(mktemp "$1.XXXXXX") && cat >"$t" && chmod "$2" "$t" && mv -f "$t" "$1"' _ "$2" "${3:-600}"
}
server_pub_copy() {  # the rdgen user cannot read $SRV_DATA: give it a validated copy of the PUBLIC key
  local k; k=$(as_user rustdesk cat "$SRV_DATA/id_ed25519.pub")
  [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "!! $SRV_DATA/id_ed25519.pub is not a public key" >&2; return 1; }
  (umask 027; printf '%s' "$k" >/etc/rdgen/server.pub.tmp) && chgrp rdgen /etc/rdgen/server.pub.tmp &&
    mv -f /etc/rdgen/server.pub.tmp /etc/rdgen/server.pub   # /etc/rdgen is root-owned
}
art() { (cd "$CD_APP" && umask 027 && as_user cortendesk "$PHP" artisan "$@" --no-interaction); }
cd_php() { (cd "$CD_APP" && umask 027 && as_user cortendesk "$PHP" "$@"); }  # cd_php <script.php>, stdin passes through
lan_ip() { ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1; }
latest_tag() {  # latest_tag <owner/repo>: via the releases/latest redirect (no API rate limit, skips prereleases)
  "${CURL[@]}" -m 60 -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed -n 's#.*/releases/tag/##p'
}
env_get() {  # env_get <file> <KEY>: value of KEY=... (no shell evaluation)
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
env_set() {  # env_set <file> <KEY> <value>: replace or append KEY=value, keep mode/owner
  local f=$1 k=$2 v=$3 tmp
  tmp=$(mktemp "$f.XXXXXX")
  grep -v "^$k=" "$f" >"$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >>"$tmp"
  chmod "$(stat -c %a "$f" 2>/dev/null || echo 640)" "$tmp"   # busybox has no --reference
  chown "$(stat -c %u:%g "$f" 2>/dev/null || echo 0:0)" "$tmp"
  mv "$tmp" "$f"
}
# ~/rustdesk-cortendesk.creds: "Label: value" lines (root-only). Values never pass through sed/regex.
creds_set() {  # creds_set <label> <value>
  local tmp
  [ -f "$CREDS" ] || (umask 077; printf 'RustDesk + CortenDesk on %s\n\n' "$(hostname)" >"$CREDS")
  tmp=$(mktemp "$CREDS.XXXXXX")
  L="$1" V="$2" awk 'BEGIN { l = ENVIRON["L"]; v = ENVIRON["V"] }
    index($0, l ":") == 1 { if (!done) printf "%-18s %s\n", l ":", v; done = 1; next }
    { print }
    END { if (!done) printf "%-18s %s\n", l ":", v }' "$CREDS" >"$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$CREDS"
}
creds_get() {  # creds_get <label>
  L="$1" awk 'BEGIN { l = ENVIRON["L"] } index($0, l ":") == 1 { sub(/^[^:]*:[ ]*/, ""); print; exit }' "$CREDS" 2>/dev/null
}
