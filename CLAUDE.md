# CLAUDE.md

This repo is a Proxmox LXC installer in the community-scripts style. It installs a native RustDesk stack in a single
LXC: marcpope/cortendesk-server (hbbs/hbbr with KeyExchange), marcpope/cortendesk (the Laravel console and API) and,
optionally, a hardened pull-model bryangerlach/rdgen. The CT runs Alpine 3.24 (OpenRC) or Debian 13 (systemd). Don't
introduce Docker.

## Build
- `install/rustdesk-cortendesk-install.sh` is generated, so never edit it. Edit `src/install.tmpl` and `src/files/**`
  (each file installs at the same path in the CT), then run `bash build.sh`. The build embeds every file as a quoted
  heredoc (so `RDFILE_EOF` must not appear in any file), writes `rdgen/patches/MANIFEST`, and runs `bash -n` and `php -l`.
- The framework runs the install script as `lxc-attach -- bash -c "$script"`, i.e. as one argv string, which Linux caps
  at 128 KiB. build.sh fails above 120 000 bytes. Large payloads such as the rdgen patches are copied in by the ct script
  with `pct exec` after `build_container`; they are never embedded.
- `shellcheck -S warning -e SC1091,SC2034,SC2154,SC1090 src/files/usr/local/bin/*` is clean. Keep it that way.

## Framework (community-scripts core/build.func, fetched at runtime)
- `catch_errors` turns on `set -Ee` and an ERR trap. On the host, any unguarded non-zero command after
  `build_container` makes the error handler offer to destroy the new CT, and it does so after 60s by default. Guard every
  whiptail call (`|| true` or `|| return 0`) and use the `wt()` and `interactive()` helpers.
- Don't source `common.sh` in the framework's shell, because the names clash. Call a tool instead, or use
  `bash -c '. common.sh; ...'`.
- Host prompts run after `build_container` and hand their values to in-CT tools over stdin (`pct exec … --stdin`). Each
  one has a `var_rd_*` env equivalent and is skipped under `PHS_SILENT=1`. The framework's `prompt_*` helpers never
  prompt inside install scripts.
- The `lib/tools.func` helpers (setup_php, setup_composer, nginx_enable_site, get_php_fpm_socket) only work on Debian;
  never call them on Alpine. Don't name any token `GITHUB_TOKEN` or `var_github_token`, because the framework puts that
  variable on curl's command line.
- The ct script seeds its banner into the framework's header cache. Upstream has no banner for this app, and without the
  seed header_info prints curl 404s.

## Runtime facts
- On Alpine, call php84 by its full path (`/usr/bin/php84`). php85 is the default there and owns /usr/bin/php. Composer
  is the pinned, sha256-verified phar in /usr/local/bin, not the apk and not setup_composer. User switching uses su-exec.
- Run artisan and php as `cortendesk` (the `art` and `cd_php` helpers in common.sh) with umask 027. Root-owned logs or
  SQLite -wal/-shm files break php-fpm. Because `opcache.validate_timestamps=0`, restart php-fpm after every code swap
  or `config:cache`.
- CortenDesk treats `.env` as the source of truth (the 1.9.1 web client reads only .env), but saved Settings rows
  (id_server, relay_server, public_key, rdgen_url) override it elsewhere, so `sync-settings.php` updates the rows that
  exist. `CORTENDESK_RDGEN_URL` must be present even when empty; if it is missing, CortenDesk falls back to a third-party
  rdgen. The admin helper renames the previous admin instead of adding a second one. Since 1.14.0, client /api/login asks
  for the TOTP (or emailed) code too and refuses passwords under force-SSO.
- CortenDesk has no release assets (we use the tag tarball plus composer). cortendesk-server has no checksums file, so
  its downloads are verified against the asset `digest` from the GitHub API. Latest versions come from the
  `releases/latest` redirect, which uses no API quota.
- hbbs keys must not contain `/` or `:` (the cortendesk-utils genkeypair loop retries) and are written with no trailing
  newline under umask 077. Always run `hbbr -k _`, otherwise it is an open relay. hbbs resolves relay hostnames once at
  startup, so restart it after changing them. 21118/21119 trust X-Real-IP and X-Forwarded-For, so nginx overwrites both.
  Never proxy 21115, the loopback admin channel. To check KeyExchange, read from 127.0.0.1:21116: the fork sends bytes
  first and official hbbs sends nothing.
- Unprivileged LXCs cap open files at 524288; the services use 65535.
- lxc-attach can hand the install a umask of 077, so install.tmpl and common.sh set `umask 022`. Secrets always get
  explicit modes (mktemp, or subshells with umask 077).
- Root must never create, write, chmod or chown a path inside a directory a service user owns, because the owner can
  swap even a root-made mktemp name for a symlink. Either do the I/O as the service user with
  `write_as <user> <dest> [mode] <src` from common.sh, or prepare the file in a root-only directory (/etc/rdgen, $BK)
  and `mv -f` it into place. Tokens reach the bootstrap on stdin (`--token-stdin`), and a stored token is written by
  rdgenbuild. The deploy discards any `.venv` that ships in the tree (`python3 -m venv --clear`, pip
  `--only-binary :all:`).
- CortenDesk sessions use the database driver, so `revokeAllAccess()` (called by set-admin.php) really logs users out.
  composer runs as root with `--no-scripts --no-plugins`; `artisan package:discover` then runs as the app user.
- Test hook: `RD_TEST_FAIL_HEALTH=1` with `cortendesk-update --force` or `rustdesk-server-update --force` fails the first
  health check once, which exercises the rollback.
- rdgen can be update-tested offline, without GitHub: use a local bare upstream repo and a local "private" repo, run
  `rdgenerator.tests.ghstub` as the API, and run the bootstrap's
  `update --upstream file://… --git-url file://… --api <stub>`. `rdgen-update` then deploys the pushed tree as a
  "retry". The stub can't simulate the "workflows registered" step after init.
- The patches in rdgen/patches apply to the base commit named in UPSTREAM. On a newer upstream,
  `rdgen-github-bootstrap update` regenerates 0009 with tools/pullify.py instead of rebasing it.
- rdgen uses two fine-grained tokens: an install token with write access and an Actions-only runtime token. User `rdgen`
  runs the web UI and the poller with the runtime token. User `rdgenbuild` (primary group rdgen, so it can read
  rdgen.env) owns /var/lib/rdgen-build and runs every step that executes upstream code: git am, pullify,
  `manage.py check` and the push. Root only deploys, piping `git archive` from rdgenbuild into tar. The install token is
  not kept by default.
- rdgen can't read /var/lib/rustdesk-server, so it gets its own copy of the public key at /etc/rdgen/server.pub.
- Django's password validators require at least 12 characters, so our admin prompts ask for 12.
- The local rdgen tree may only change after a successful push, because the dispatch inputs must match the workflows.
- `init` checks that GitHub lists the generator workflows with the runtime token (`--runtime-token-stdin`, second
  stdin line), because listing needs Actions: read and the install token has no Actions permission (GitHub answers
  403, and the check is skipped). GitHub lists workflows even when Actions are disabled. It can leave workflows first
  pushed to a non-default branch unregistered; after 90 s init pushes an empty commit on top of the tree to make GitHub
  re-read them. The ghstub models this (`runtime_token`, `install_actions_status`, `stale_registration`).
- Client self-update (RustDesk 1.4.9 source): custom clients hide the "new version" card and the update-check checkbox;
  only Auto update (allow-auto-update, Windows, installed, daily, and only when the OFFICIAL release is newer) runs.
  It downloads rdgen's downloadLink (sed into updater.rs) and runs it as an EXE (`update_msi` is false for custom
  clients), following redirects. rdgen suggests `<RDGEN_UPDATE_BASE>/<windows-x86_64|windows-x86>/<version>/<name>.exe`;
  nginx (/etc/nginx/rustdesk-clients.conf) hands it to client-update.php, which reads the DB read-only and 302s to
  /downloads/<id> of the newest published rdgen row with a strictly newer version, else 404 (no reinstall loop).
  RDGEN_UPDATE_BASE = APP_URL + /clients (rdgen-setup, rustdesk-config). refresh-ct.sh adds the include to old installs.
- Linux app names (patch 0016, validation.linux_app_name): the Linux workflow pastes env.appname unquoted into build.py
  shell commands, the deb Package / rpm Name, unit and desktop file names, and RustDesk's Linux runtime derives its unit,
  process matching, /etc paths and URI scheme from the lowercased app name. So Linux builds send one slug
  ([a-z0-9-]) as both the workflow appname and custom.txt app-name; names that start with a digit, are shorter than 2,
  contain "rustdesk", or are in linux_reserved_names.txt are refused. pullify also stages custom_.txt in
  /usr/share/<appname>/ (upstream left it in /usr/share/rustdesk/, unread by renamed clients) and fixes the Flatpak ID and
  launchable. Upstream rdgen still has this bug (its PR #308 was closed unmerged).
- Mac signing lives in pullify.py (generated workflow, patch 0009): with MACOS_P12_BASE64 the app is re-signed with
  Apple's codesign from a temporary keychain before "Create DMG" (hardened runtime, timestamp, --deep, like RustDesk's
  release workflow; Apple's Developer ID intermediates are fetched with pinned sha256), the DMG is signed with the same
  identity, and with an App Store Connect key (APPLE_API_* or MACOS_NOTARIZE_JSON) rcodesign notarizes and staples it.
  The rcodesign download is pinned by sha256 (RCODESIGN_SHA256). Verified against Apple by real builds (see below).
- `pct enter` / `pct exec` shells have PATH /sbin:/bin:/usr/sbin:/usr/bin, so the install (and refresh-ct.sh) links
  every tool from /usr/local/bin into /usr/bin. Inside scripts, common.sh sets a full PATH.
- `tools/refresh-ct.sh <ctid>` (host) copies src/files and the patches into an existing CT and runs
  `rdgen-setup --rebuild`, then `rdgen-setup --push` when a build repo is configured and an install token is stored
  (/var/lib/rdgen-build/install.token, rdgenbuild 0600), then `rdgen-update`. --push reads the token as rdgenbuild and
  pipes it to the bootstrap's `init` (stdin, never argv); exit 10 = no stored token. Never make the operator
  create a new token while the stored one works. Install-time config is otherwise not
  touched, except the additions newer versions need (console links, alert relay).
- --rebuild builds from UPSTREAM's base-commit, which can be older than what the daily rdgen-update had installed
  (2026-10-04: the daily update moved a CT to upstream with RustDesk 1.5.0; refresh-ct.sh rolled it back to
  39babbc and 1.5.0 vanished from the form). Hence refresh-ct.sh runs rdgen-update after the push (newest master if
  the patches apply, else the base stays), and --push records the tree's real upstream (HEAD~<patch count>; the
  bootstrap's empty "register the workflows" commit is commit-tree only) as .upstream in bootstrap.json.
- The daily update applies the patches with `git am -3` on upstream master; a patch whose context upstream changed
  (0020 on a8cd6ea: the version line in forms.py) stops it ("update NOT applied, keeping the current version"):
  rebase the series locally (`git rebase --onto <new> <old base>`, regenerate 0009 from the 0008 tree with pullify),
  move UPSTREAM's base-commit, re-export, re-verify (tools/rdgen-rebase.py does all of it). Base since 2026-10-24:
  70a628c (2026-10-23 "remove slug_appname since it was causing issues"; 0aa18fc, f1dcd1c, 1ba8738, cdb79ac, 234c0f8 before). /api/status keeps our "files" from the
  database (name, size, sha256, /api/download url): upstream's version listed exe/<uuid>, which the pull model never
  fills (builds live in ARTIFACT_ROOT/<uuid>), and ignored
  deleted builds. The platform override, "on" booleans and 1.5.0 in the API are upstream's; validation runs after
  the override. settings.py keeps our DATABASES (DATA_DIR, timeout 20): upstream's WAL init_command served the
  push-model callbacks (save_custom_client/updategh) we removed, and -wal/-shm files would break the ownership rules.
- A clean `git am` is not enough: a new key upstream adds to the views.py config dict reaches secrets.json, and the
  runner's validate.py refuses unknown keys, so every build would fail at "Load Secrets" (update_public_key,
  2026-10-17). test_pull.test_dispatched_config_passes_the_runner_check runs the really dispatched config through
  validate.py; keep it passing on every rebase. New `.github/patches` downloads from upstream master make pullify
  stop ("unknown patch download form"); teach rewrite_fetches the form (wget, Invoke-WebRequest, curl -o).
- Automation (2026-10-18). tools/rdgen-rebase.py is the hand rebase as a tool: start (the series on its base, then
  `git rebase -i --onto` with a scripted todo that replaces the pullify patch's pick by `exec ... regen`), regen,
  finish (format-patch --no-signature, UPSTREAM, build.sh), verify (git am round trip, the bootstrap's update as a dry
  run with RDGEN_VERIFY_TESTS=0, the suite once, actionlint against rdgen-old). Exit 10/20/21/30; WORK/report.md.
  Replayed against 234c0f8->94fe8ef (10), ->cdb79ac (20 at 0001, then 21 at regen until pullify learned curl -o) and
  0e83379->234c0f8 (20 at 0003). .github/workflows/rdgen-upstream.yml: rebase (read-only; skips when branch
  rdgen/upstream-<sha12> exists) -> repair (claude-code-action pinned, CLAUDE_CODE_OAUTH_TOKEN, github_token given so
  no OIDC, read-only, --add-dir WORK; then finish again on its own) -> open-pr (the only writer; applies the diff only
  if it touches rdgen/patches/*, rdgen/README, CLAUDE.md or the generated install script). CI deps:
  .github/rdgen-ci-requirements.txt (hash-pinned, >= 2 weeks old), actionlint 1.7.12 by sha256
  (.github/actions/rdgen-ci-tools). Tested on GitHub 2026-10-18 (a private copy of this repository): clean path (onto 84a0f54) -> PR in 3 min, patches identical to a local run; repair
  path (onto the OLDER 94fe8ef) -> Claude resolved 0001 like the hand rebase, saw it was a rollback, refused to weaken
  tests, verify failed (exit 30) -> draft PR "repair INCOMPLETE". Since then a failed verification proposes no changes
  (empty commit + report; the attempt is the run artifact `series`/attempt.diff), and start refuses targets older than
  the base (status "older", --allow-older for tests). claude-code-action rejects `push` events ("Unsupported event
  type: push"); test from a branch with workflow_dispatch. To start runs and read logs from a shell, use a
  fine-grained token (that repository only: Actions RW, pull requests R) via curl -H @headerfile, never argv.
- Repair trigger (2026-10-19): GitHub never fired the repository's cron (private repo, active workflow, default
  branch, pushed after registration), so the workflow is dispatch-only. rdgen-update calls `patch-source
  request-repair` on exit 4 (patches do not apply, or the test gate failed); it POSTs a workflow_dispatch (ref = the
  patch-source branch, onto empty = master) with /etc/rdgen/patch-source-dispatch.token (root 0600; `rdgen-setup
  --patch-source dispatch-token` reads it from stdin and checks it with a GET), the token only in curl's stdin config.
  The outcome goes to /var/lib/rustdesk-update/rdgen-repair, which rustdesk-update appends to the rdgen:4 warning.
  rustdesk-update does not rerun rdgen-update for the same versions, so one request per failing upstream commit.
  Tested against a local stub (RDGEN_PATCH_SOURCE_API). Install script: 119,752 bytes after this.
  A CT-started run took the clean path and opened its pull request. Clean PRs (status clean: rebase without conflicts,
  every check passed, nothing edited) are squash-merged by open-pr (gh pr merge --squash --delete-branch, since
  2026-10-19). Since 2026-10-24 verified repairs merge the same way: the owner asked for no review step, which
  only delayed fixes (PR #10 sat as a draft overnight). A repair stays a draft when the independent
  finish fails, when Claude writes hold.md (the only fix would weaken the hardening, or it is unsure), or when the
  repository variable RDGEN_REPAIR_REVIEW is true. Review the merged repairs yourself when you work here.
- Keeping the repository current (2026-10-21): after a successful update whose upstream is newer than the series'
  base, rdgen-update calls `patch-source request-sync <upstream>`, which starts rdgen-upstream.yml (clean path ->
  auto-merge); so the base follows what the CTs run, once per upstream move (the CT rebuilds once more for the
  re-exported series). publish-public.yml pushes the tree to the public copy as one commit on top of its history
  (secret PUBLIC_DEPLOY_KEY = a write deploy key of the public repo; optional secret PUBLIC_DENY_REGEX blocks a
  matching tree); open-pr starts it after an auto-merge (GITHUB_TOKEN merges start no push workflows).
- Patch source (rdgen/patch-source, payload, not embedded): rdgen-setup --patch-source <owner/repo> makes
  /etc/rdgen/patch-source.key (ed25519, read-only deploy key) and patch-source.env (root 0600); ssh uses only
  rdgen/github_known_hosts (api.github.com/meta = ssh-keyscan, 2026-10-18). rdgen-update: labels <upstream>+<series7>
  (SERIESF /var/lib/rustdesk-update/rdgen-series, "local" after refresh-ct.sh), `stage` fetches into
  /var/cache/rdgen-patch-source (root 0700), refuses links/other names/MANIFEST mismatches (exit 6, rustdesk-update
  warns), stages $RDGEN_PATCHES.next; the bootstrap update runs with --force on it; only a successful push swaps it in.
  Tested with a local harness (git insteadOf), not in a CT yet.
- The install script is at 119.75 KB of the 120 000-byte limit (2026-10-19). The next growth has to move rdgen-only
  tools (rdgen-publish, rdgen-update, rdgen-setup) into the rdgen payload like patch-source, or compress the embed.
- app_version (upstream 2026-10-18, API only; merged via the workflow's first real repair, PR #4): a DISPATCH input
  (not in secrets.json, so validate.py never sees it), sent only when set; validation.py allows x.y.z or x.y.z.w;
  pullify passes it to "Set custom app version" as env APP_VERSION (it lands in sed, whose e flag runs commands).
  Patch 0026: the setup job (fetch-encrypted-secrets.yml, written by 0007; every build job needs it) refuses any other
  value, like version/proto/build_uuid. A patch after 0009 may edit a pullify-touched file only outside the lines
  pullify rewrites; rdgen-rebase.py verify proves both paths (git am and the bootstrap's skip-0009-then-pullify).
  ghstub accepts exactly the dispatch inputs the tree's workflows declare.
- update_public_key (upstream, API only; patch 0024): ed25519 key, base64 only (allow_custom_update.py tries
  base64 first, so hex would decode to 48 wrong bytes). With it the client's update check goes to
  <downloadLink>/api/version/latest (rustdesk-api), github.com-only download checks are relaxed and metadata
  signed with the key is trusted. CortenDesk serves no such endpoint; our form has no field for it.
- Upstream's Linux DRM job (build-rustdesk-linux-drm, an extra <name>-unattended-wayland-x86_64.deb; RustDesk 1.5.0's
  build.py has --drm, 1.4.9's not) lost its "Detect DRM support" step on 2026-10-04 while its build/upload steps kept
  testing DRM_SUPPORTED. pullify's linux_drm_rewrite restores the detection, gates the --drm build on it, adds
  `if: inputs.linux_arch != 'aarch64'` and `continue-on-error: true` (the poller fails any run that is not a success).
- `rdgen-github-bootstrap init` pushes to the repository's default branch (an empty repo already reports the name it
  will use; GitHub's first commit is replaced when it holds only README.md, LICENSE and/or .gitignore) and waits for the API to show it as the default.
  `rdgen-setup` copies the branch from bootstrap.json into `GHBRANCH`, which rdgen dispatches on. Don't hardcode a branch.
- CortenDesk's `/downloads` page is public: no login, and only `is_published` gates a row. A client carries its
  preset permanent password and any password set under Other (default-connect-password, proxy-password,
  preset-address-book-password, a proxy-url with credentials) in readable form, so such builds are never published
  automatically: rdgen refuses the choice (forms.embeds_secret) and `rdgen_publish pending` reports them as hidden.
- Build hand-off: when a build whose choice is hidden or published succeeds, the rdgen poller touches
  /var/lib/rdgen/publish.pending. `rdgen-publish` (cron or a systemd timer, every minute) does nothing else without it.
  It lists builds with `manage.py rdgen_publish pending` as rdgen, reads each file as rdgen, and pipes it to
  `import-download.php` as cortendesk. That script checks rdgen's size and sha256, writes through a temp file opened
  with 'x', names the copy like CortenDesk's uploader, hides older imports of the same file name when publishing, and
  skips rows it already made for that build. rdgen-publish holds /run/rustdesk-update.lock (root-only, opened by
  `update_lock`; `as_user` closes fd 9), and `rustdesk-update` waits up to 30 minutes for it. Alpine's busybox flock
  has no `-w`: wait with `update_lock_wait <seconds>` (a `flock -n` loop). cortendesk-update takes the lock itself
  unless it runs under rustdesk-update (`RUSTDESK_UPDATE_LOCKED=1`).
- CortenDesk's own alerts (AppriseNotifications) only POST to an Apprise API server: `{endpoint}/notify/{key}` with
  title, body, type. For the discord/apprise methods, alert-relay.php (php-fpm, nginx on 127.0.0.1:8296 only,
  /etc/nginx/rustdesk-alert-relay.conf linked into http.d or sites-enabled) checks the key in
  /etc/cortendesk/alert-relay.key (0640 root:cortendesk) and queues one file per alert in /var/spool/cortendesk-alerts
  (0700 cortendesk). `cortendesk-alerts` (root; Alpine cron each minute, Debian timer every 15 s with
  ConditionDirectoryNotEmpty) reads each file as cortendesk, defuses @mentions with a zero-width space and sends it with
  `rustdesk-notify send`; failures stay queued for an hour. `cortendesk-alerts install` is idempotent (install.tmpl,
  refresh-ct.sh) and connects CortenDesk when NOTIFY_METHOD is discord/apprise; `connect --if-unset` leaves an endpoint
  that points elsewhere alone and is silent when already connected. apprise-seed.php only sets event switches when none
  is on. The settings page never shows endpoint values, only that one is set.
- Share links (rdgen 0017): /builds lists builds within RDGEN_RETENTION_DAYS; ShareLink tokens are token_urlsafe(32)
  (43 chars), expire in 1/7/30 days capped at the build's deletion, and are deleted (not flagged) on "Delete link".
  The console server block passes only `^/share/<43>(/<file>)?$` to 127.0.0.1:8000 as the normalized `$uri`,
  GET/HEAD only, Host 127.0.0.1, Cookie/Authorization stripped. RDGEN_SHARE_BASE = APP_URL + /share (rdgen-setup,
  rustdesk-config).
- Deleting a build (rdgen 0018, poller.discard_build): terminal builds only (the poller never touches them again); sets
  GithubRun.deleted_at and files=[] first, then drops share links and the build dir. Every lookup filters deleted_at
  (_get_run_status, stored_file, the list, share links, rdgen_publish pending). The row stays until prune_local so
  prune_remote still deletes a failed GitHub run. CortenDesk's own delete removes its file (model deleting hook);
  the two copies are independent.
- macOS: RustDesk reads <app>/Contents/Resources/custom.txt (src/common.rs load_custom_client, every 1.4.x and master;
  rdgen's allowCustom.py renames it custom_.txt). Upstream rdgen wrote Contents/MacOS/custom_.txt: unread, and
  rcodesign/codesign treat files there as Mach-O ("Invalid magic number" in upstream's "Sign macOS app bundle", which
  pullify now drops; it also pasted the p12 secrets into the script). Server, key and API server are compiled in by
  sed, so a wrong custom_.txt location only loses password, permissions and options. Signing is verified against
  Apple only by real builds: one signed the app and the DMG with a Developer ID certificate.
- rcodesign's "unified" API key JSON wants private_key = base64 DER (the .p8 body without BEGIN/END lines or line
  breaks), as `rcodesign encode-app-store-connect-api-key` writes it. The full PEM gives "invalid unified api key".
  Checked locally with rcodesign 0.22.0 for Linux: a key that parses gets as far as "do not know how to notarize"
  on a dummy file.
- Clients POST check-ins (/api/heartbeat, /api/sysinfo) and logins to their API server. Behind Cloudflare an http://
  console URL gets a 301 to https, a redirected POST becomes a GET (405), and the console never hears from the client
  (seen on an install whose APP_URL was http://<public host>: the setup prompt pre-fills http://<IP>, and only the
  host was swapped). rustdesk-config now switches such a URL to https (probe: GET / redirects to https://same
  host) and `rustdesk-config --check` tests check-ins and the /ws/id WebSocket. CortenDesk builds the web client's
  ws:// or wss:// from APP_URL's scheme. rdgen sets override-settings api-server only for Incoming Only builds.
- CortenDesk stores a hand-typed device ID verbatim (spaces included); heartbeats match rustdesk_id exactly, and a
  trashed (Recycle Bin) device swallows its heartbeats. require_device_approval=1 sends new devices to Pending.
- Actions cost (private repo, measured): Mac build = 2 Mac jobs x 30-40 min x 10 = ~600-700 of the Free plan's 2,000;
  Windows/Linux ~100, so failed Mac builds (early signing bugs) were what ran up a bill. GitHub's docs
  (2026) list per-minute rates (Linux $0.006, Windows $0.010, macOS $0.062) and say self-hosted usage is free; the
  10x/2x multiplier wording is gone from the docs but matches real bills.
- Mac jobs (rdgen 0020 + pullify): input mac_arch (both | x86_64 | aarch64) builds the matrix with fromJSON; rdgen
  sends it only for macOS and only when not "both" (older build repos keep accepting defaults). runs-on takes repo
  variables RDGEN_RUNNER_MACOS_X86_64 / _AARCH64 (runner labels), else the GitHub image. Self-hosted-only steps are
  gated by runner.environment == 'self-hosted' (prepare: xcodebuild -version, the tools tools/runner-mac.sh installs
  (python magick potrace create-dmg pkg-config cmake ninja wget jq pod rustup), RDGEN_BIN on PATH,
  RDGEN_DMG_ARGS=--skip-jenkins); the three brew install steps are GitHub-only (hosted_only()). Homebrew moved Intel
  macOS to Tier 3 in Sept 2026: of the 61 formulae in that closure, 45 had no Intel bottle (llvm, gcc, imagemagick,
  cocoapods -> ruby -> rust -> llvm@22), hours of compiling. GitHub-hosted behaviour is unchanged. Intel Macs
  are the self-hosted case this targets.
- tools/runner-mac.sh: no Homebrew, no sudo, nothing outside ~/actions-runner. micromamba (GitHub API digest) makes
  a conda-forge env rdgen-tools/conda (python=3.12 ruby=3.3 cmake=4.4 ninja wget jq pkg-config imagemagick, pinned
  to the macos-15 image's versions), gem installs cocoapods 1.17.0 into conda/share/rubygems (conda's GEM_HOME; plain
  ruby doesn't look there, so bin/pod is a wrapper setting GEM_HOME/GEM_PATH and running ruby -x on the binstub),
  potrace 1.16 and create-dmg 1.3.0 build from source (Homebrew's sha256), rustup with --no-modify-path
  (dtolnay/rust-toolchain would otherwise install rustup and edit shell profiles). rdgen-tools/bin holds only the
  commands the build uses; bin/pkg-config runs conda's pkg-config.bin (conda's pkg-config script always adds its
  prefix) with PKG_CONFIG_LIBDIR defaulting to an empty dir. .env: LANG/LC_ALL, CARGO_HOME, RUSTUP_HOME; .path:
  rdgen-tools/bin, cargo/bin, /usr/bin:/bin:/usr/sbin:/sbin (no Homebrew).
  actionlint (rhysd, release binary) validates the generated workflows; only upstream findings remain.
- Self-hosted runners keep state between jobs, unlike GitHub's (first real builds, 2026-10-05):
  - Docker steps (run-on-arch) run as root and leave root-owned files in _work (cargo target/, flutter/build): every
    later checkout on the runner CT failed with EACCES, bridge jobs included, so all builds failed. runner-lxc.sh registers
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/libexec/rdgen-runner-job-started.sh (sudo find _work ! -user runner
    -exec chown); installed by hand on the first runner CT (6245 files repaired).
  - Flutter's SDK stays in the tool cache: the dropdown patch is already applied on the second build, and the Windows
    step (not continue-on-error) failed. pullify's flutter_patch_rewrite guards it with git apply --reverse --check.
  - Windows: python.org's layout has no python3.exe; build.py runs as `python3`. runner-windows.ps1 hard-links it
    (done by hand on the first Windows runner). Mac: decrypt-secrets runs `pip`; runner-mac.sh links conda's pip.
  - Swatinem/rust-cache (cache-bin, default true) records every file in $CARGO_HOME/bin at job start and deletes them
    in its post step after a SUCCESSFUL job: the Mac's first successful build (03:35 UTC) deleted rustup, and every
    later Mac build stopped at the prep step's tool check (Linux/Windows silently reinstall rustup via
    dtolnay/rust-toolchain). pullify's rust_cache_rewrite adds cache-bin: ${{ runner.environment != 'self-hosted' }}
    to every rust-cache step in ROUTED workflows; runner-mac.sh also keeps rustup-init in rdgen-tools and registers
    ACTIONS_RUNNER_HOOK_JOB_STARTED=rdgen-tools/job-started.sh, which reinstalls rustup when it is missing.
  - The AppImage job runs `sudo appimage-builder` on the runner itself: it built the AppImage, then stopped at the
    .zsync file (no zsyncmake; GitHub's image has the zsync package), failing every Linux build with all formats.
    runner-lxc.sh installs zsync (done by hand on the first runner CT; a full appimage-builder run of 1.5.0 then passed).
  - The DRM job ran 40 min on a runner CT and failed (run-on-arch exit 255): on a self-hosted Linux runner it now runs only
    with vars.RDGEN_LINUX_DRM == 'true' (DRM_JOB_IF).
- Self-hosted runners (rdgen 0021 + pullify): every runs-on in ROUTED workflows (Linux, Windows, macOS generators and
  bridge/fetch-encrypted-secrets/third-party helpers; not Android) takes vars.RDGEN_RUNNER_LINUX / _LINUX_ARM /
  _WINDOWS (labels rdgen-linux, rdgen-windows). On self-hosted: "Maximize build space" rm -rf and "Set Swap Space"
  are skipped, Linux/Windows build jobs check prerequisites first, the Windows Flutter engine path follows
  RUNNER_TOOL_CACHE. Linux form choices linux_arch (both/x86_64/aarch64) and linux_formats (all/deb) are sent only
  when not the default. tools/runner-lxc.sh (host): unprivileged Ubuntu 22.04 LXC, nesting+keyctl+fuse, docker.io,
  runner user with NOPASSWD sudo, /opt/artifacts for vcpkg; tested on a throwaway CT (docker, run-on-arch flags,
  FUSE/appimagetool, bwrap in a privileged container OK; arm64 containers fail: no binfmt in the LXC; run-on-arch
  prunes all Docker images each build). tools/runner-windows.ps1 (VM, PS 5.1): Chocolatey + VS 2022 Build Tools
  (VCTools, v142 for TopMostWindow, ATL, NuGet build tasks, .NET 4.8 SDK), git with unix tools, pwsh, python312,
  nuget, dotnet 8, imagemagick, jq; local admin rdgen-runner (random password via ACTIONS_RUNNER_INPUT_
  WINDOWSLOGONPASSWORD); refuses domain controllers. Neither has run a real job yet.
- Debian needs python3-django from trixie-backports (5.2, for LoginRequiredMiddleware). The venv uses
  --system-site-packages, so it has no bin/gunicorn; run `.venv/bin/python3 -m gunicorn`.

## Rules
- Everything committed to this repository is published to its public copy (.github/workflows/publish-public.yml, on
  every push to the working branch): no personal infrastructure details (domains, IPs, CT/VM ids, user or account
  names, tokens, run ids, billing). Keep such notes outside the repository.
- The repo is GPL-3.0-or-later (LICENSE). Keep the community-scripts MIT notice in NOTICE and in the ct/install
  file headers, and credit upstream projects in the README.
- Secrets never go on argv or into logs. Use stdin, root-only files, `curl -K` or `-H @file`, and jq `env.X`.
- The creds file, /etc/rustdesk-update.env, the backups and the rdgen install token are root-only (the token belongs to
  rdgenbuild). Service env files are group-readable (0640).
- Every updater downloads and stages first (leaving the running system alone), then backs up, swaps, health-checks and
  rolls back on failure. Nothing after the swap may exit before the health check or rollback. The orchestrator sends
  one notification per run.

## Testing
Test on throwaway CTs only. Pick IPs that are free by ARP after `ip neigh del <ip> dev vmbr0`, because destroyed CTs
leave stale entries behind.
```bash
TERM=xterm PHS_SILENT=1 mode=generated var_os=alpine var_ctid=<id> var_net=<ip>/24 var_gateway=<gw> \
var_pw="$(openssl rand -hex 12)" var_rd_admin_user=tester var_rd_admin_pass="$(openssl rand -hex 8)" \
bash ct/rustdesk-cortendesk.sh </dev/null
```
Test both Alpine and Debian. Then, in the CT, exercise `rustdesk-update` (up to date, `--force`, and injected failures
that trigger a rollback), `rustdesk-admin`, `rustdesk-config`, `rustdesk-notify` (against a local `nc -l` listener) and
`rdgen-setup --local-only`, which needs no GitHub. For the hand-off to CortenDesk, point rdgen at
`rdgenerator.tests.ghstub` (RDGEN_GITHUB_API, GHUSER/REPONAME/GHBEARER, RDGEN_API_TOKEN), give the stub an
`artifacts_for` that returns files, start builds through `/api/generate`, and check the rows and `/downloads`. The
GitHub side of rdgen needs a real private repo and tokens.
Destroy the test CTs afterwards.
