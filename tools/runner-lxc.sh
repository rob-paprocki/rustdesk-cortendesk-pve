#!/usr/bin/env bash
# runner-lxc.sh: a GitHub Actions self-hosted runner for rdgen's Linux builds (and the small Linux jobs of every
# build) in a dedicated unprivileged Ubuntu 22.04 LXC with Docker. Jobs on a self-hosted runner use no Actions
# minutes. Run on the Proxmox host as root:
#   bash runner-lxc.sh [--repo owner/name | --from-ct <rdgen ctid>] [--token-stdin]   create, install, register
#   bash runner-lxc.sh --no-register                                                  create and install only
#   bash runner-lxc.sh --register <ctid> [--repo ... | --from-ct ...] [--token-stdin] register (again) later
# Settings (env): var_ctid (next free id), var_hostname (rdgen-runner), var_storage (local-lvm), var_tmpl_storage
#   (local), var_cores (4), var_ram (8192 MB), var_swap (4096 MB), var_disk (100 GB), var_bridge (vmbr0),
#   var_net (dhcp, or <ip>/<cidr>) and var_gateway
# The registration token (GitHub: the build repo's Settings > Actions > Runners > New self-hosted runner) is read
# hidden, or from stdin, and reaches the runner's config.sh only as ACTIONS_RUNNER_INPUT_TOKEN: never on a command
# line, never on disk.
# The CT is for the runner only. Builds get Docker and passwordless sudo in it, and every Linux build prunes all of
# its Docker images and volumes (rustdesk-org/run-on-arch-action). Docker inside needs the features nesting, keyctl
# and fuse (run-on-arch passes --device /dev/fuse to every container).
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "!! $*" >&2; exit 1; }

MODE=create REGISTER=yes REPO="" FROM_CT="" TOKEN_STDIN=no TOKEN="" CTID=${var_ctid:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:?--repo owner/name}; shift 2 ;;
    --from-ct) FROM_CT=${2:?--from-ct <ctid>}; shift 2 ;;
    --token-stdin) TOKEN_STDIN=yes; shift ;;
    --no-register) REGISTER=no; shift ;;
    --register) MODE=register; CTID=${2:?--register <ctid>}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ "$(id -u)" = 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam not found: run this on the Proxmox host"

LABEL=rdgen-linux
REPO_RE='^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$'
# what GitHub's ubuntu-22.04 image has and the rdgen Linux, bridge and secrets jobs use on the host without
# installing it (the build itself runs in Docker; vcpkg builds its libraries on the host)
PACKAGES="docker.io sudo git curl wget jq unzip zip xz-utils tar ca-certificates gnupg lsb-release
  python3 python3-pip python3-venv python3-setuptools python-is-python3
  build-essential pkg-config cmake ninja-build autoconf automake autoconf-archive libtool gettext nasm yasm
  file patchelf fakeroot strace desktop-file-utils squashfs-tools libfuse2 zsync rsync tree imagemagick libva-dev"

get_repo() {   # the build repo to register with: --repo, an rdgen CT's settings, or a prompt
  if [ -z "$REPO" ] && [ -n "$FROM_CT" ]; then
    REPO=$(pct exec "$FROM_CT" -- sh -c 'u=$(sed -n "s/^GHUSER=//p" /etc/rdgen/rdgen.env | tail -n1)
      r=$(sed -n "s/^REPONAME=//p" /etc/rdgen/rdgen.env | tail -n1); [ -n "$u" ] && [ -n "$r" ] && printf "%s/%s" "$u" "$r"') ||
      die "CT $FROM_CT has no GHUSER/REPONAME in /etc/rdgen/rdgen.env"
  fi
  if [ -z "$REPO" ]; then
    [ -t 0 ] || die "no build repository: use --repo owner/name or --from-ct <rdgen ctid>"
    read -r -p "Build repository (owner/name): " REPO
  fi
  [[ "$REPO" =~ $REPO_RE ]] || die "the repository must look like owner/name"
}

get_token() {
  if [ "$TOKEN_STDIN" = yes ]; then
    IFS= read -r TOKEN || true
  else
    [ -t 0 ] || die "no terminal for the token prompt: use --token-stdin"
    echo "Registration token: on GitHub open $REPO > Settings > Actions > Runners > New self-hosted runner,"
    echo "choose Linux and x64, and copy only the value after --token in its ./config.sh line (valid for an hour)."
    read -rs -p "Token (hidden): " TOKEN
    echo
  fi
  [[ "$TOKEN" =~ ^[A-Za-z0-9]{20,200}$ ]] || die "that does not look like a runner registration token"
}

create_ct() {
  CTID=${CTID:-$(pvesh get /cluster/nextid)}
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "invalid CT id '$CTID'"
  if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then die "id $CTID is already in use"; fi
  local ts=${var_tmpl_storage:-local} tmpl net
  echo "==> template"
  pveam update >/dev/null 2>&1 || echo "(pveam update failed; using the templates already listed)"
  tmpl=$( { pveam available --section system 2>/dev/null | awk '{print $2}'; pveam list "$ts" 2>/dev/null | awk '{print $1}'; } |
    sed 's#.*/##' | grep -E '^ubuntu-22\.04-standard_.*_amd64\.tar\.zst$' | sort -uV | tail -n1)
  [ -n "$tmpl" ] || die "no ubuntu-22.04-standard template available"
  pveam list "$ts" | grep -q "/$tmpl" || pveam download "$ts" "$tmpl" >/dev/null
  net="name=eth0,bridge=${var_bridge:-vmbr0},ip=dhcp"
  if [ -n "${var_net:-}" ] && [ "$var_net" != dhcp ]; then
    [[ "$var_net" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || die "var_net must be dhcp or <ip>/<cidr>"
    net="name=eth0,bridge=${var_bridge:-vmbr0},ip=$var_net${var_gateway:+,gw=$var_gateway}"
  fi
  echo "==> CT $CTID from $tmpl"
  pct create "$CTID" "$ts:vztmpl/$tmpl" --hostname "${var_hostname:-rdgen-runner}" --ostype ubuntu \
    --unprivileged 1 --features nesting=1,keyctl=1,fuse=1 --onboot 1 --tags rdgen-runner \
    --cores "${var_cores:-4}" --memory "${var_ram:-8192}" --swap "${var_swap:-4096}" \
    --rootfs "${var_storage:-local-lvm}:${var_disk:-100}" --net0 "$net" \
    --description "GitHub Actions runner ($LABEL) for rdgen builds. Made by runner-lxc.sh; Docker in it is for builds only." \
    >/dev/null
  pct start "$CTID"
  local i
  for i in $(seq 60); do
    pct exec "$CTID" -- getent hosts archive.ubuntu.com >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "CT $CTID has no network after two minutes"
}

install_ct() {   # packages, the runner user, Docker, and the runner itself (sha256 from the GitHub API)
  echo "==> packages, Docker and the runner in CT $CTID (several minutes)"
  pct exec "$CTID" -- env PACKAGES="$PACKAGES" bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8   # the template has no other locale (as on GitHub)
echo LANG=C.UTF-8 >/etc/default/locale
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $PACKAGES >/dev/null
id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
usermod -aG docker runner
printf 'runner ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/runner
chmod 0440 /etc/sudoers.d/runner
visudo -cf /etc/sudoers.d/runner >/dev/null
# lukka/run-vcpkg clones vcpkg into /opt/artifacts/vcpkg as the runner user (writable on GitHub's image too)
install -d -o runner -g runner /opt/artifacts
systemctl enable --now docker >/dev/null 2>&1
dir=/home/runner/actions-runner
if [ ! -x "$dir/config.sh" ]; then
  api=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)
  pick='.assets[] | select(.name | test("^actions-runner-linux-x64-[0-9.]+\\.tar\\.gz$"))'
  url=$(jq -r "$pick | .browser_download_url" <<<"$api")
  dig=$(jq -r "$pick | .digest // empty" <<<"$api")
  [[ "$url" == https://github.com/actions/runner/releases/download/* ]] || { echo "!! no runner download in the release" >&2; exit 1; }
  [[ "$dig" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "!! the GitHub API gave no sha256 digest for $url" >&2; exit 1; }
  curl -fsSL -o /tmp/actions-runner.tar.gz "$url"
  echo "${dig#sha256:}  /tmp/actions-runner.tar.gz" | sha256sum -c --quiet - || { echo "!! runner download does not match its digest" >&2; exit 1; }
  install -d -o runner -g runner "$dir"
  runuser -u runner -- tar -xzf /tmp/actions-runner.tar.gz -C "$dir"
  rm -f /tmp/actions-runner.tar.gz
  # the runner's .NET needs (libicu and friends); it probes many libicu versions, so its output goes to a log
  "$dir/bin/installdependencies.sh" >/tmp/runner-deps.log 2>&1 || { cat /tmp/runner-deps.log >&2; exit 1; }
  rm -f /tmp/runner-deps.log
  echo "    runner $(basename "$url" .tar.gz | sed 's/^actions-runner-linux-x64-//') installed in $dir"
fi
EOF
}

register_ct() {   # config.sh reads the token from ACTIONS_RUNNER_INPUT_TOKEN; --replace takes over the name on GitHub
  echo "==> registering CT $CTID with $REPO as $LABEL-$CTID"
  pct exec "$CTID" -- test -x /home/runner/actions-runner/config.sh || die "CT $CTID has no runner installed"
  printf '%s\n' "$TOKEN" | pct exec "$CTID" -- env REPO="$REPO" NAME="$LABEL-$CTID" LABEL="$LABEL" bash -c '
set -euo pipefail
IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN
export ACTIONS_RUNNER_INPUT_TOKEN LANG=C.UTF-8   # config.sh records LANG for the service (.env)
cd /home/runner/actions-runner
if [ -f .runner ]; then   # registered before: drop the local registration and the service first
  ./svc.sh stop >/dev/null 2>&1 || true
  ./svc.sh uninstall >/dev/null 2>&1 || true
  rm -f .runner .credentials .credentials_rsaparams .service
fi
# Docker build steps run as root and leave root-owned files in the work folder (cargo target/, flutter build/).
# GitHub throws its machines away after each job, this one stays: the next checkout could not clean those files and
# failed with EACCES. The runner runs this hook before every job.
install -d /usr/local/libexec
cat >/usr/local/libexec/rdgen-runner-job-started.sh <<"HOOK"
#!/bin/bash
# rdgen (tools/runner-lxc.sh): give files a root container left in the work folder back to the runner user
w=/home/runner/actions-runner/_work
[ -d "$w" ] && sudo -n find "$w" ! -user runner -exec chown -h runner:runner {} + 2>/dev/null
exit 0
HOOK
chmod 0755 /usr/local/libexec/rdgen-runner-job-started.sh
runuser -u runner -- sh -c "printf \"LANG=C.UTF-8\\nACTIONS_RUNNER_HOOK_JOB_STARTED=%s\\n\" \
  /usr/local/libexec/rdgen-runner-job-started.sh >.env"   # env.sh keeps values already in .env
runuser -u runner -- ./config.sh --unattended --replace --url "https://github.com/$REPO" --name "$NAME" \
  --labels "$LABEL" --work _work >/dev/null
unset ACTIONS_RUNNER_INPUT_TOKEN
./svc.sh install runner >/dev/null
./svc.sh start >/dev/null
systemctl is-active --quiet "$(cat .service)" && echo "    runner service $(cat .service) is running"'
}

if [ "$MODE" = register ]; then
  pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID does not exist"
  get_repo
  get_token
  register_ct
else
  if [ "$REGISTER" = yes ]; then get_repo; get_token; fi   # asked first: the install takes minutes
  create_ct
  install_ct
  [ "$REGISTER" = no ] || register_ct
fi
TOKEN=""

ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
echo
if [ "$MODE" = register ] || [ "$REGISTER" = yes ]; then
  echo "Runner CT $CTID ($ip) is registered with $REPO as $LABEL-$CTID (label: $LABEL)."
  echo "Next, on GitHub: $REPO > Settings > Secrets and variables > Actions > Variables > New repository variable:"
  echo "  RDGEN_RUNNER_LINUX = $LABEL"
  echo "Linux builds and the small Linux jobs of every build then run here instead of on GitHub's machines."
else
  echo "Runner CT $CTID ($ip) is installed but not registered. To register it:"
  echo "  1. GitHub: the build repo > Settings > Actions > Runners > New self-hosted runner, Linux, x64; copy the token"
  echo "  2. here: bash $0 --register $CTID --repo <owner/name>    (or --from-ct <rdgen ctid>)"
  echo "  3. GitHub: Settings > Secrets and variables > Actions > Variables: RDGEN_RUNNER_LINUX = $LABEL"
fi
