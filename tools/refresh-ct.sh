#!/usr/bin/env bash
# refresh-ct.sh <ctid>: bring an existing RustDesk-CortenDesk CT up to this checkout without reinstalling.
# Copies the tools (src/files: /usr/local/bin/*, the helper library, the CortenDesk scripts) and the rdgen patches
# into the CT, then rebuilds rdgen from them if it is installed and pushes that to the build repo when an install
# token is stored (rdgen-setup --push). Data, the console, logins, keys and tokens stay.
# Settings written only at install time (nginx, PHP, env files) are not changed, apart from what newer versions add:
# the console's links for rdgen clients (/clients/, /share/) and the relay for CortenDesk's own alerts.
# Run on the Proxmox host as root, from anywhere: bash /path/to/rustdesk-server-pve/tools/refresh-ct.sh 103
set -euo pipefail
id=${1:?usage: refresh-ct.sh <ctid>}
root=$(cd "$(dirname "$0")/.." && pwd)
[ -d "$root/src/files" ] && [ -s "$root/rdgen/patches/UPSTREAM" ] || { echo "run this from a full checkout" >&2; exit 1; }
pct exec "$id" -- test -f /usr/local/lib/rustdesk-cortendesk/common.sh ||
  { echo "CT $id has no RustDesk-CortenDesk install" >&2; exit 1; }

echo "==> tools -> CT $id"
# regular files only (no directory entries, so the CT's directory modes stay as they are)
(cd "$root/src/files" && find . -type f -print0 | tar --null -T - --owner=0 --group=0 -czf -) |
  pct exec "$id" -- sh -c 'umask 022 && tar -xzf - -C / && chmod 755 /usr/local/bin/rustdesk-* /usr/local/bin/rdgen-* /usr/local/bin/cortendesk-* &&
    for t in /usr/local/bin/rustdesk-* /usr/local/bin/rdgen-* /usr/local/bin/cortendesk-*; do ln -sfn "$t" /usr/bin/; done'

echo "==> nginx: rdgen links on the console (self-update, share)"
# installs from before /clients/ existed: include the snippet (just copied with the tools) in the console's server block
pct exec "$id" -- sh -c 'site=/etc/nginx/http.d/cortendesk.conf; [ -f "$site" ] || site=/etc/nginx/sites-available/cortendesk
  grep -q rustdesk-clients.conf "$site" && exit 0
  cp "$site" /root/cortendesk-nginx.bak
  awk "{ print } /^ *index index.php;\$/ { print \"    include /etc/nginx/rustdesk-clients.conf;   # self-update links for rdgen clients\" }" \
    /root/cortendesk-nginx.bak >"$site"
  if ! nginx -t -q; then cp /root/cortendesk-nginx.bak "$site"; echo "!! nginx rejected the change; left as it was" >&2; exit 1; fi'
pct exec "$id" -- sh -c 'nginx -t -q || { echo "!! nginx rejects the new snippets; nothing reloaded" >&2; exit 1; }
  if command -v systemctl >/dev/null; then systemctl reload nginx; systemctl restart php8.4-fpm
  else rc-service --quiet nginx reload; rc-service --quiet php-fpm84 restart; fi'   # opcache: re-read the PHP scripts

echo "==> CortenDesk alerts -> notifications (local relay)"
pct exec "$id" -- /usr/local/bin/cortendesk-alerts install ||
  echo "!! the alert relay is not set up; run 'cortendesk-alerts install' inside CT $id" >&2

echo "==> rdgen patches -> CT $id"
# the copied series is this checkout's, not the patch source's (rdgen-update compares and records it again)
tar -C "$root" -czf - rdgen/patches rdgen/patch-source rdgen/github_known_hosts | pct exec "$id" -- sh -c 'mkdir -p /usr/local/share/rustdesk-cortendesk &&
  rm -rf /usr/local/share/rustdesk-cortendesk/rdgen/patches /var/lib/rustdesk-update/rdgen-series &&
  tar -xzf - -C /usr/local/share/rustdesk-cortendesk &&
  chown -R root:root /usr/local/share/rustdesk-cortendesk && chmod -R u=rwX,go=rX /usr/local/share/rustdesk-cortendesk'

if pct exec "$id" -- test -x /opt/rdgen/.venv/bin/python3; then
  echo "==> rebuilding rdgen in CT $id (a few minutes)"
  pct exec "$id" -- env RDGEN_SETUP_FROM_REFRESH=1 /usr/local/bin/rdgen-setup --rebuild   # a failure stops here
  # the build repo needs the same tree (workflows <-> dispatch inputs): push it with the stored install token
  if ! pct exec "$id" -- grep -q '^GHUSER=.' /etc/rdgen/rdgen.env; then
    :   # no build repo yet (rdgen-setup --local-only, or the GitHub step never finished)
  elif pct exec "$id" -- test -s /var/lib/rdgen-build/install.token; then
    echo "==> pushing the rebuilt rdgen to your build repo (stored install token)"
    if pct exec "$id" -- /usr/local/bin/rdgen-setup --push; then
      # the rebuild starts from the tested base commit, which may be older than what the daily update had installed:
      # move on to the newest upstream master the patches apply to, as the daily update would (or keep the base)
      echo "==> rdgen: newest upstream"
      pct exec "$id" -- /usr/local/bin/rdgen-update ||
        echo "!! rdgen stays on the tested base; the daily update tries the newest upstream again" >&2
    else
      echo "!! not pushed; inside CT $id run: rdgen-setup --github (with a new install token if it expired)" >&2
    fi
  else
    echo "No install token is stored in CT $id: run 'rdgen-setup --github' inside it to push the rebuilt rdgen."
  fi
else
  echo "rdgen is not installed in CT $id; run 'rdgen-setup' inside it to add it"
fi
