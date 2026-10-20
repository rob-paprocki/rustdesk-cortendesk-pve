#!/usr/bin/env bash
# runner-mac.sh: make this Mac a GitHub Actions self-hosted runner for rdgen's Mac builds. Jobs on a self-hosted
# runner use no Actions minutes. Run it on the Mac as your own user (not root, not with sudo):
#   bash runner-mac.sh --repo owner/name                 install, then register (asks for the token)
#   bash runner-mac.sh --repo owner/name --no-register   install only
#   bash runner-mac.sh --register --repo owner/name      register (again) later
# Needs Xcode, installed and opened once: 16.4 is the one GitHub's Mac images build with. Everything else the build
# uses goes into ~/actions-runner/rdgen-tools, without Homebrew (it no longer has prebuilt packages for Intel Macs),
# sudo or changes to your shell profile: conda-forge's prebuilt Python (with pip), Ruby, CMake, Ninja, wget, jq,
# pkg-config and ImageMagick; CocoaPods; potrace and create-dmg built from their release sources; Rust (rustup). Deleting
# ~/actions-runner removes all of it.
# The runner gets the label rdgen-mac; then set the repository variable RDGEN_RUNNER_MACOS_X86_64 (Intel Mac) or
# RDGEN_RUNNER_MACOS_AARCH64 (Apple Silicon) to it, and choose that kind of Mac under "Mac builds" in rdgen's form.
# The registration token (GitHub: the build repo's Settings > Actions > Runners > New self-hosted runner) is read
# hidden, or from stdin with --token-stdin, and reaches config.sh only as ACTIONS_RUNNER_INPUT_TOKEN: never on a
# command line, never on disk. The runner runs as a LaunchAgent, so this user has to stay logged in.
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "!! $*" >&2; exit 1; }

MODE=install REGISTER=yes REPO="" TOKEN_STDIN=no TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:?--repo owner/name}; shift 2 ;;
    --register) MODE=register; shift ;;
    --no-register) REGISTER=no; shift ;;
    --token-stdin) TOKEN_STDIN=yes; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ "$(uname -s)" = Darwin ] || die "this is for macOS"
[ "$(id -u)" != 0 ] || die "run this as your own user, not as root"
[[ "$REPO" =~ ^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$ ]] || die "use --repo owner/name (the private build repository)"
[ "$MODE" = install ] || REGISTER=yes

# the system's tools only: whatever Homebrew or conda put on PATH must not leak into what this builds
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset GEM_HOME GEM_PATH RUBYOPT PYTHONHOME PYTHONPATH CONDA_PREFIX MAMBA_ROOT_PREFIX CARGO_HOME RUSTUP_HOME
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # CocoaPods needs a UTF-8 locale

LABEL=rdgen-mac
DIR=$HOME/actions-runner
TOOLS=$DIR/rdgen-tools
RUNNER_PATH=$TOOLS/bin:$TOOLS/cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin   # jobs: this toolchain, then the system's
case "$(uname -m)" in
  x86_64) ARCH=x64 CONDA_ARCH=osx-64 RUST_HOST=x86_64-apple-darwin VAR=RDGEN_RUNNER_MACOS_X86_64 KIND="Intel only" ;;
  arm64) ARCH=arm64 CONDA_ARCH=osx-arm64 RUST_HOST=aarch64-apple-darwin VAR=RDGEN_RUNNER_MACOS_AARCH64 KIND="Apple Silicon only" ;;
  *) die "unknown Mac architecture $(uname -m)" ;;
esac
# the versions GitHub's macos-15 image has (actions/runner-images), so a build here behaves like one there
CONDA_PKGS="python=3.12 ruby=3.3 cmake=4.4 ninja=1.13 wget=1.25 jq=1.8 pkg-config imagemagick"
COCOAPODS=1.17.0
# release sources, with the sha256 that Homebrew's formulae pin for them
POTRACE_URL=https://potrace.sourceforge.net/download/1.16/potrace-1.16.tar.gz
POTRACE_SHA256=be8248a17dedd6ccbaab2fcc45835bb0502d062e40fbded3bc56028ce5eb7acc
CREATE_DMG_VERSION=1.3.0
CREATE_DMG_URL=https://github.com/create-dmg/create-dmg/archive/refs/tags/v$CREATE_DMG_VERSION.tar.gz
CREATE_DMG_SHA256=c50d2bc97c3d6292642bac55f530d247eaf4bf65ee605f26b4caf339383e381c

xcode_ready() { [[ "$(xcode-select -p 2>/dev/null)" == *.app/Contents/Developer ]] && xcodebuild -version >/dev/null 2>&1; }

check_mac() {   # Flutter's macOS build needs the full Xcode, the Command Line Tools are not enough
  if xcode_ready; then
    echo "    $(xcodebuild -version | head -n1), macOS $(sw_vers -productVersion), $(uname -m)"
  else
    local why="Xcode is missing or not selected (xcode-select -p: $(xcode-select -p 2>/dev/null || echo none)). Install Xcode
    16.4 (developer.apple.com/download/all, or the App Store), put it in /Applications, open it once, then run:
    sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept"
    [ "$REGISTER" = no ] || die "$why"
    echo "    !! $why"
    echo "    !! the tools install now; register the runner once Xcode is ready"
  fi
  xcrun --find clang >/dev/null 2>&1 || die "no compiler: install Xcode, or the Command Line Tools (xcode-select --install)"
  local free_gb
  free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  [ "${free_gb:-0}" -ge 40 ] || echo "    !! only ${free_gb} GB free in $HOME; a Mac build needs about 40 GB"
}

fetch() {   # fetch URL SHA256 FILE: download, then check the sha256
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | shasum -a 256 -c --quiet - || die "$(basename "$3") from $1 does not match its sha256"
}

gh_asset() {   # gh_asset OWNER/REPO NAME-REGEX: "url sha256" of that asset of the latest release (GitHub API digest)
  local found url dig
  found=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" | /usr/bin/python3 -c '
import json, re, sys
for a in json.load(sys.stdin)["assets"]:
    if re.fullmatch(sys.argv[1], a["name"]):
        print(a["browser_download_url"], (a.get("digest") or "").replace("sha256:", "", 1))
        break' "$2")
  url=${found%% *} dig=${found#* }
  [[ "$url" == "https://github.com/$1/releases/download/"* ]] || die "no $2 in the latest release of $1"
  [[ "$dig" =~ ^[0-9a-f]{64}$ ]] || die "the GitHub API gave no sha256 digest for $url"
  echo "$url $dig"
}

install_runner() {   # the latest runner for this architecture
  if [ -x "$DIR/config.sh" ]; then echo "    runner already in $DIR"; return 0; fi
  local asset tmp
  asset=$(gh_asset actions/runner "actions-runner-osx-$ARCH-[0-9.]+\.tar\.gz")
  tmp=$(mktemp -d)
  fetch "${asset%% *}" "${asset#* }" "$tmp/runner.tar.gz"
  mkdir -p "$DIR"
  tar -xzf "$tmp/runner.tar.gz" -C "$DIR"
  rm -rf "$tmp"
  echo "    runner $(basename "${asset%% *}" .tar.gz | sed "s/^actions-runner-osx-$ARCH-//") installed in $DIR"
}

install_tools() {
  local tmp asset t
  tmp=$(mktemp -d)
  mkdir -p "$TOOLS/bin"
  # conda-forge packages through micromamba, a single binary that reads no ~/.condarc and writes no shell profile
  if [ ! -x "$TOOLS/micromamba" ]; then
    asset=$(gh_asset mamba-org/micromamba-releases "micromamba-$CONDA_ARCH")
    fetch "${asset%% *}" "${asset#* }" "$tmp/micromamba"
    install -m 0755 "$tmp/micromamba" "$TOOLS/micromamba"
  fi
  if [ "$(cat "$TOOLS/conda/.rdgen-packages" 2>/dev/null)" != "$CONDA_PKGS" ]; then
    rm -rf "$TOOLS/conda"
    # shellcheck disable=SC2086   # one word per package
    MAMBA_ROOT_PREFIX="$TOOLS/mamba" "$TOOLS/micromamba" create --yes --quiet --no-rc --prefix "$TOOLS/conda" \
      --override-channels --channel conda-forge $CONDA_PKGS >/dev/null
    echo "$CONDA_PKGS" >"$TOOLS/conda/.rdgen-packages"
    MAMBA_ROOT_PREFIX="$TOOLS/mamba" "$TOOLS/micromamba" clean --all --yes --quiet >/dev/null
  fi
  # gems live where conda's Ruby activation puts them (GEM_HOME); its default gems stay visible through GEM_PATH
  local gems
  gems=$TOOLS/conda/share/rubygems
  export GEM_HOME="$gems" GEM_PATH="$gems:$("$TOOLS/conda/bin/ruby" -e 'print Gem.default_dir')"
  "$TOOLS/conda/bin/gem" list --installed cocoapods --version "$COCOAPODS" >/dev/null ||
    "$TOOLS/conda/bin/gem" install --no-document --version "$COCOAPODS" cocoapods >/dev/null
  # potrace and create-dmg: not in conda-forge, small and quick to build
  if ! "$TOOLS/potrace/bin/potrace" --version 2>/dev/null | grep -q '^potrace 1\.16'; then
    fetch "$POTRACE_URL" "$POTRACE_SHA256" "$tmp/potrace.tar.gz"
    tar -xzf "$tmp/potrace.tar.gz" -C "$tmp"
    (cd "$tmp"/potrace-1.16 && ./configure --prefix="$TOOLS/potrace" --disable-dependency-tracking >/dev/null &&
      make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null) || die "potrace did not build"
  fi
  if [ "$("$TOOLS/bin/create-dmg" --version 2>/dev/null)" != "create-dmg $CREATE_DMG_VERSION" ]; then
    fetch "$CREATE_DMG_URL" "$CREATE_DMG_SHA256" "$tmp/create-dmg.tar.gz"
    tar -xzf "$tmp/create-dmg.tar.gz" -C "$tmp"
    make -C "$tmp/create-dmg-$CREATE_DMG_VERSION" install prefix="$TOOLS" >/dev/null
  fi
  # Rust: the build's rust-toolchain action installs the toolchain it needs, but would install rustup itself into
  # ~/.cargo and add it to your shell profile when there is none. The installer stays in $TOOLS for the job-started
  # hook (below), which puts rustup back if something deletes it from $CARGO_HOME/bin.
  if [ ! -x "$TOOLS/rustup-init" ]; then
    local sum
    sum=$(curl -fsSL "https://static.rust-lang.org/rustup/dist/$RUST_HOST/rustup-init.sha256" | awk '{print $1}')
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for rustup-init"
    fetch "https://static.rust-lang.org/rustup/dist/$RUST_HOST/rustup-init" "$sum" "$tmp/rustup-init"
    install -m 0755 "$tmp/rustup-init" "$TOOLS/rustup-init"
  fi
  # Swatinem/rust-cache deleted rustup after a successful build (it removes what was in $CARGO_HOME/bin before the job;
  # rdgen's workflows now set cache-bin false on self-hosted runners). The runner runs this before every job.
  cat >"$TOOLS/job-started.sh" <<HOOK
#!/bin/bash
# rdgen (tools/runner-mac.sh): rustup back into \$CARGO_HOME/bin if something deleted it; the toolchains stay
[ -x "$TOOLS/cargo/bin/rustup" ] || CARGO_HOME="$TOOLS/cargo" RUSTUP_HOME="$TOOLS/rustup" "$TOOLS/rustup-init" -y \\
  --quiet --no-modify-path --default-toolchain none --profile minimal >/dev/null 2>&1
exit 0
HOOK
  chmod 0755 "$TOOLS/job-started.sh"
  "$TOOLS/job-started.sh"
  [ -x "$TOOLS/cargo/bin/rustup" ] || die "rustup did not install"
  rm -rf "$tmp"
  # the build sees only these commands of the toolchain, not everything conda installed alongside them
  for t in python3 python pip3 pip cmake ctest cpack ninja wget jq magick; do
    [ -x "$TOOLS/conda/bin/$t" ] || die "conda-forge did not install $t"
    ln -sfn "../conda/bin/$t" "$TOOLS/bin/$t"
  done
  [ -f "$gems/bin/pod" ] || die "CocoaPods did not install pod"
  rm -f "$TOOLS/bin/pod"
  cat >"$TOOLS/bin/pod" <<EOF
#!/bin/sh
# rdgen: CocoaPods on the toolchain's Ruby, with the gems where conda's Ruby keeps them
export GEM_HOME="$GEM_HOME" GEM_PATH="$GEM_PATH"
exec "$TOOLS/conda/bin/ruby" -x "$gems/bin/pod" "\$@"
EOF
  chmod 0755 "$TOOLS/bin/pod"
  unset GEM_HOME GEM_PATH
  ln -sfn ../potrace/bin/potrace "$TOOLS/bin/potrace"
  [ -x "$TOOLS/conda/bin/pkg-config.bin" ] || die "conda-forge did not install pkg-config.bin"
  mkdir -p "$TOOLS/pkgconfig-none"
  cat >"$TOOLS/bin/pkg-config" <<EOF
#!/bin/sh
# rdgen: only the .pc files a build points to (PKG_CONFIG_PATH), not the libraries this toolchain brought along.
# Hence the real binary (conda's pkg-config script adds its own directories) and an empty default directory.
: "\${PKG_CONFIG_LIBDIR:=$TOOLS/pkgconfig-none}"
export PKG_CONFIG_LIBDIR
exec "$TOOLS/conda/bin/pkg-config.bin" "\$@"
EOF
  chmod 0755 "$TOOLS/bin/pkg-config"
  (
    export PATH="$TOOLS/bin:$TOOLS/cargo/bin:$PATH" CARGO_HOME="$TOOLS/cargo" RUSTUP_HOME="$TOOLS/rustup"
    printf '    %s\n' "$(python3 --version)" "$(cmake --version | head -n1)" "ninja $(ninja --version)" \
      "$(wget --version | head -n1)" "$(jq --version)" "$(magick -version | head -n1)" "CocoaPods $(pod --version)" \
      "$(potrace --version | head -n1)" "$(create-dmg --version)" "pkg-config $(pkg-config --version)" \
      "$(rustup --version 2>/dev/null)"
  )
}

configure_env() {   # what the runner's jobs see: this toolchain first, then the system's (not Homebrew's)
  cd "$DIR"
  printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\nCARGO_HOME=%s\nRUSTUP_HOME=%s\nACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' \
    "$TOOLS/cargo" "$TOOLS/rustup" "$TOOLS/job-started.sh" >.env
  PATH="$RUNNER_PATH" ./env.sh >/dev/null   # writes .path; keeps the .env values above
  [ "$(cat .path)" = "$RUNNER_PATH" ] || die "the runner's PATH (.path) is not $RUNNER_PATH"
}

register_runner() {
  if [ "$TOKEN_STDIN" = yes ]; then
    IFS= read -r TOKEN || true
  else
    [ -t 0 ] || die "no terminal for the token prompt: use --token-stdin"
    echo "Registration token: on GitHub open $REPO > Settings > Actions > Runners > New self-hosted runner,"
    echo "choose macOS, and copy only the value after --token in its ./config.sh line (valid for an hour)."
    read -rs -p "Token (hidden): " TOKEN
    echo
  fi
  [[ "$TOKEN" =~ ^[A-Za-z0-9]{20,200}$ ]] || die "that does not look like a runner registration token"
  cd "$DIR"
  if [ -f .runner ]; then   # registered before: drop the local registration and the LaunchAgent first
    ./svc.sh stop >/dev/null 2>&1 || true
    ./svc.sh uninstall >/dev/null 2>&1 || true
    rm -f .runner .credentials .credentials_rsaparams .service
  fi
  PATH="$RUNNER_PATH" ACTIONS_RUNNER_INPUT_TOKEN=$TOKEN ./config.sh --unattended --replace \
    --url "https://github.com/$REPO" --name "$LABEL-$(hostname -s)" --labels "$LABEL" --work _work >/dev/null
  TOKEN=""
  configure_env   # config.sh runs env.sh too, which rewrites .path from its own PATH: write the runner's again
  ./svc.sh install >/dev/null
  ./svc.sh start >/dev/null
  echo "    runner $LABEL-$(hostname -s) is registered and running (LaunchAgent)"
}

echo "==> checking this Mac"
check_mac
if [ "$MODE" = install ]; then
  echo "==> GitHub Actions runner"
  install_runner
  echo "==> build tools, in $TOOLS (the first time takes a while)"
  install_tools
fi
[ -x "$DIR/config.sh" ] && [ -x "$TOOLS/bin/pod" ] || die "nothing installed in $DIR yet: run this without --register first"
configure_env
if [ "$REGISTER" = yes ]; then
  echo "==> registering with $REPO"
  register_runner
  echo
  echo "Next, on GitHub: $REPO > Settings > Secrets and variables > Actions > Variables > New repository variable:"
  echo "  $VAR = $LABEL"
  echo "and in rdgen's form choose Mac builds: $KIND."
elif [ -f "$DIR/.runner" ]; then
  echo
  echo "Installed; the runner was registered before. A running runner picks up changes when restarted:"
  echo "  launchctl kickstart -k gui/$(id -u)/$(basename "$(cat "$DIR/.service" 2>/dev/null)" .plist)"
else
  echo
  echo "Installed, not registered. To register: bash $0 --register --repo $REPO"
fi
echo "Keep this user logged in and the Mac awake while builds may run (System Settings > Energy, or: sudo pmset -c sleep 0)."
