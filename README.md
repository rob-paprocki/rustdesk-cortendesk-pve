# rustdesk-server-pve: self-hosted RustDesk in a Proxmox LXC (community-scripts style)

This installs a self-hosted RustDesk stack in one unprivileged LXC, natively (no Docker), on Alpine 3.24 or Debian 13:

| Component | What it is |
|---|---|
| [cortendesk-server](https://github.com/marcpope/cortendesk-server) | The official RustDesk server 1.1.16 (hbbs/hbbr) plus the KeyExchange that clients 1.4.1+ need while signed in to a console. Official hbbs lacks it, so signed-in clients fail with "Failed to secure tcp". |
| [CortenDesk](https://github.com/marcpope/cortendesk) | Web console and RustDesk API server: devices, users, groups, address books, strategies, audit logs, OIDC, 2FA, a browser client, and a client downloads page. PHP 8.4 + nginx + SQLite. |
| [rdgen](https://github.com/bryangerlach/rdgen) (optional) | Builds custom, preconfigured RustDesk clients for Windows, Linux, Android and macOS. The patches in `rdgen/patches/` add a login, CSRF, fixes for the file-path leaks, and a pull model: builds run in your private GitHub repo and the LXC downloads the results. GitHub never connects to the LXC, and rdgen is LAN only. Finished builds can go straight into CortenDesk's Client Downloads. |

It uses the [community-scripts](https://community-scripts.org) framework. The container defaults to 2 cores, 2 GB RAM and a 16 GB disk; change them in Advanced mode.

## Install (on the Proxmox host, as root)
Download the repo and run the ct script from it:
```bash
curl -fsSL https://github.com/rob-paprocki/rustdesk-cortendesk-pve/archive/refs/heads/stable.tar.gz | tar -xz
bash rustdesk-cortendesk-pve-stable/ct/rustdesk-cortendesk.sh
```
1. Choose Alpine or Debian. Advanced mode lets you set the CT ID, a static IP and the root password (for console/SSH login).
2. When the install is done, the script asks for:
   - The console admin: username, email and a password of at least 12 characters. The rdgen login uses the same credentials.
   - The addresses. The public ID/relay host is a DNS-only name or IP that clients reach on ports 21115-21117. The console URL is what browsers and the clients' *API server* setting use, e.g. `https://rustdesk.example.com` through a reverse proxy or Cloudflare Tunnel. Last comes the IP of your reverse proxy or tunnel connector. You need it when the console URL is https through a proxy on another host, because without it pages load `http://` assets that browsers block. It also makes the logs show real client IPs.
   - Notifications: none, a Discord webhook, Apprise (Telegram, ntfy, email and 100+ other services), or an existing Apprise API server. CortenDesk's own alerts go to the same place (see [Notifications](#notifications)).
   - rdgen: your private GitHub repo and two tokens (see [rdgen](#rdgen-custom-clients)).

   You can skip any of these and do it later inside the CT.

For an unattended install, every prompt has an env equivalent (replace the values):
```bash
PHS_SILENT=1 mode=generated var_os=alpine var_ctid=<id> var_net=<ip>/24 var_gateway=<gw> var_pw='<root pw>' \
var_rd_admin_user=admin var_rd_admin_pass='<console pw>' var_rd_admin_email=you@example.com \
var_rd_public_host=rd.example.com var_rd_console_url=https://rustdesk.example.com var_rd_proxy_ip=<proxy ip> \
var_rd_notify=discord var_rd_notify_url='https://discord.com/api/webhooks/…' \
var_rd_rdgen=yes var_rd_rdgen_repo=<owner>/rdgen-build var_rd_rdgen_install_token=… var_rd_rdgen_runtime_token=… \
var_rd_rdgen_store_token=no \
bash rustdesk-cortendesk-pve-stable/ct/rustdesk-cortendesk.sh
```

## Inside the CT
| Command | What it does |
|---|---|
| `cat ~/rustdesk-cortendesk.creds` | Shows the logins, the server key, the client settings and the rdgen URL (root-only file) |
| `rustdesk-admin` | Changes the console admin and the rdgen login. It renames the current admin instead of adding a second one. |
| `rustdesk-config` | Changes the public host, console URL and proxy IP in every place that uses them: hbbs, CortenDesk's `.env` and saved settings, and rdgen's defaults |
| `rustdesk-config --check` | Tests the console URL the way clients (check-ins) and the web client (WebSocket) use it |
| `rustdesk-notify setup` / `test` | Configures or tests notifications |
| `cortendesk-alerts connect` | Points CortenDesk's own alerts at your notifications again, e.g. after you changed them under Settings → Notifications |
| `rdgen-setup` / `rdgen-setup --github` | Installs rdgen later, or redoes only its GitHub step (leave the token blank to reuse the stored one) |
| `rdgen-setup --push` | Pushes the installed rdgen to your build repo with the stored install token, asking nothing |
| `rdgen-publish --retry <build uuid>` | Copies a finished rdgen build into CortenDesk's Client Downloads again, e.g. after a failure (the uuid is in the build page's URL) |
| `rustdesk-update` | Updates the stack now. It also runs daily at about 04:00. |
| `update` | Upgrades the OS packages (apk/apt), then runs `rustdesk-update` |

## Ports
| Port | Proto | Purpose | Expose |
|---|---|---|---|
| 80 | TCP | CortenDesk console, client API, the web client's WebSocket bridge (`/ws/*`), the Windows clients' update links (`/clients/*`) and rdgen's share links (`/share/*`) | Through your reverse proxy or Cloudflare Tunnel (HTTPS), with WebSocket upgrades forwarded |
| 21115-21117 | TCP | NAT test, ID/signalling, relay | Router port forward, DNS-only (grey-cloud) hostname |
| 21116 | UDP | ID / hole punching | Router port forward |
| 21118, 21119 | TCP | hbbs/hbbr WebSocket | Keep internal; nginx proxies them on `/ws/id` and `/ws/relay` |
| 8190 | TCP | rdgen web UI | LAN only (nginx allows RFC1918 addresses only, and rdgen requires a login) |
| 8296 | TCP | Relay for CortenDesk's own alerts | Never: it listens on 127.0.0.1 only |

Never put a reverse proxy in front of 21115: hbbs accepts admin commands there from 127.0.0.1.

## Client configuration
In the RustDesk client, open Settings → Network → ID/Relay server and set:
- ID server and Relay server: your public host
- API server: the console URL
- Key: the `Server key` line from the creds file

The console's *Client Downloads* page can host installers, and rdgen builds them with all of this already set.

## rdgen (custom clients)
1. On GitHub, create a private repository first, e.g. `rdgen-build`, and leave it empty. The installer can't create it, because its tokens are limited to that one repository. If you let GitHub add a README, license or .gitignore, the installer replaces that first commit. Actions must be allowed, which is the default (Settings > Actions > General). Don't fork rdgen, because a fork of a public repo is public.
2. Create two fine-grained tokens, both limited to that repository:
   - The install/update token needs Contents RW, Workflows RW and Secrets RW. It pushes the patched tree and sets the `ZIP_PASSWORD` secret. The CT keeps it only if you say so (the default is no), and keeping it is what lets rdgen update itself. A kept token is readable only by the unprivileged `rdgenbuild` user, which is also the user that runs every step executing upstream rdgen code. If you don't keep it, you get a notification when rdgen has an update and apply it with `rdgen-update --token-stdin`.
   - The runtime token needs Actions RW. rdgen uses it to dispatch builds and to download and delete the results. It is stored in `/etc/rdgen/rdgen.env` (root:rdgen 0640).

   Because the tokens are separate, a compromised rdgen web process still cannot change workflows or secrets.
3. Answer the rdgen prompt, or run `rdgen-setup` in the CT.
4. Open `http://<lxc-ip>:8190/`. CortenDesk's Build Installers link points there.

rdgen's form comes filled in with this server's host, port, key and API address, and each Custom Server field explains what it changes in the client. The *Other* section explains the `key=value` format and the difference between default and override settings. It also has a **Browse client options** dialog listing the 120 documented RustDesk options the form has no control for (a toggle adds the 20 it does set), with a filter and buttons that add a line to either box, and it checks both boxes as you type.

### App names on Linux
RustDesk on Linux names its package, folders and systemd service after the app name, so Linux builds use it lowercased, with spaces and other characters turned into hyphens: "Rescue Client (Acme IT)" becomes `rescue-client-acme-it`. Other platforms and CortenDesk's labels keep the full name.

rdgen refuses a Linux app name in four cases, and the form shows this as you type:
- it starts with a digit;
- it has fewer than two letters or digits;
- it contains "rustdesk";
- it's already the name of a Linux command, package or service, like `ssh` or `screen`. Installing the client would replace that program.

### Builds in CortenDesk's Client Downloads
The form asks whether to add the finished files to CortenDesk's Client Downloads. The choices are:
- **No**
- **Hidden** (the default). The files are listed in the console under Client Downloads, where you can publish them.
- **Published**. The files also go on CortenDesk's `/downloads` page and replace earlier rdgen copies of the same file name there. Files you uploaded yourself stay published.

About a minute after the build finishes, `rdgen-publish` copies the files over. Each copy is checked against the size and sha256 that rdgen recorded. You get a notification when it's done, or if it fails (retry with `rdgen-publish --retry <uuid>`).

CortenDesk's `/downloads` page needs no login. A client built with a password inside (the permanent password, or a password option such as `default-connect-password` or `proxy-password` under Other) carries it in readable form. Such a build always arrives hidden, and the form won't let you choose "published" for it. To get it to the machine it's for, use a share link.

### Recent builds and share links
**Recent builds** (top right of the builder) lists your builds of the last 30 days with their files, so you can download a build again after leaving its page.

rdgen keeps its own copy of every build for those 30 days, separate from CortenDesk. Deleting a client under Client Downloads removes CortenDesk's copy, but rdgen's copy stays. **Delete** on a finished or failed build removes rdgen's copy at once, along with its share links, and the build disappears from the list. If its files haven't been added to Client Downloads yet, they won't be. A copy already in Client Downloads stays until you delete it there.

For a finished build, **Create share link** makes a private link like `https://<console>/share/<token>`. Whoever opens it can download that build's files without a login. Use it to send a client with a password inside to the person who installs it, instead of putting it on the public `/downloads` page.
- A link works for 1, 7 or 30 days, and never longer than the build is kept. **Delete link** ends it at once.
- The page shows how often each link was downloaded.
- The token is 32 random bytes, so links can't be guessed. Anyone the link reaches can read a password inside the client, so send it only to the person who needs it.
- The console passes only `/share/<token>` and `/share/<token>/<file>` on to rdgen. The rest of rdgen stays LAN-only.

### Keeping Windows clients up to date
RustDesk custom clients don't show a "new version" prompt. They update only through **Auto update** (Windows, installed clients), which you can turn on for a build with `allow-auto-update=Y` under Other. Once a day, if RustDesk has released a version newer than the client, the client downloads the build's update URL and runs it.

For Windows builds of a 1.4.x version, the form fills in that URL with a link on your console: `https://<console>/clients/windows-x86_64/<version>/<configuration>.exe`. The console answers with the newest build of that configuration that you **published**, but only if its RustDesk version is newer than the one in the link. Otherwise it answers 404, so a client never reinstalls the build it already runs.

So when RustDesk releases a new version and rdgen offers it, rebuild your configuration with that version and publish it, and clients with Auto update on install it within a day. Notes:
- A rebuild with the same version (for example, only a changed setting) is not pushed to clients, because RustDesk only updates to newer versions.
- Leave "Remove notification for new versions" unticked: it also turns off the update check.
- Nightly builds only update from RustDesk's GitHub releases.

### Signed and notarized Mac clients
Without an Apple certificate, Mac builds are ad-hoc signed. Users then have to approve each new build under **System Settings → Privacy & Security → Open Anyway**, and grant Screen Recording and Accessibility again. With a paid Apple Developer account, add these Actions secrets to your build repo (**Settings → Secrets and variables → Actions**):

| Secret | What it is |
|---|---|
| `MACOS_P12_BASE64` | Your *Developer ID Application* certificate with its private key, exported as a `.p12` and base64-encoded |
| `MACOS_P12_PASSWORD` | The password you gave the `.p12` |
| `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_ID`, `APPLE_API_KEY_P8` | An App Store Connect API key (role Developer): the Issuer ID, the Key ID, and the full text of the `.p8` file |

Mac builds are then signed with Apple's codesign the way RustDesk signs its releases, the DMG is notarized by Apple, and the ticket is stapled to it. Macs open the app without warnings, and permissions survive updates. The secrets stay on GitHub and never pass through the LXC.

Upstream rdgen has its own signing step for these secrets. It signs with rcodesign, pastes the secrets into the script, and fails on every custom client, because it tries to sign the settings file as a program. The patched workflow leaves it out.

Mac clients read their settings file (`custom_.txt`: preset password, permissions, Other settings) from `Contents/Resources`, but upstream rdgen puts it in `Contents/MacOS`. So Mac clients built before this fix used only the compiled-in server, key and API server, and ignored everything else. Rebuild them.

When you start a build, rdgen sends the config (server, key, preset password, branding) to GitHub as an AES-encrypted workflow input. The build runs in your repo's Actions and uploads the clients as artifacts that expire after a day. The poller in the LXC downloads them, then deletes the artifacts and the successful run.

Costs and caveats:
- Private repos use your Actions minutes. The Free plan includes 2,000 a month. GitHub's Mac minutes cost about ten times as much as Linux ones (Windows almost twice), and they use up the free minutes at that pace. A Windows or a Linux build uses about 100. A Mac build runs a Mac machine for each kind of Mac for 30-40 minutes: roughly 600-700 for Intel and Apple Silicon, half that with the form's **Mac builds** set to one kind, even when it fails at the end. A Mac of your own builds for free (see below).
- Set a budget so GitHub stops builds instead of charging you: **Settings → Billing and licensing → Budgets and alerts**, an Actions budget with "Stop usage when budget limit is reached". At $0, builds that still use GitHub's machines stop once the free minutes are gone. Builds that run entirely on your own runners (below) keep going.
- Windows builds are unsigned, so SmartScreen warns. Mac builds are too, unless you add the signing secrets above.
- Custom clients also need the KeyExchange that cortendesk-server provides.

### Builds on machines of your own
Jobs on a self-hosted runner use no Actions minutes, and they keep running when the budget is spent. Each kind of machine is optional; whatever has no runner of its own still builds on GitHub. Every runner gets a label, and a repository variable in your build repo (**Settings → Secrets and variables → Actions → Variables**) sends that kind of job to it:

| Machine | Set up with | Repository variable |
|---|---|---|
| Linux: an Ubuntu 22.04 LXC with Docker, for Linux builds and the small Linux jobs every build has | `bash tools/runner-lxc.sh --from-ct <rdgen ctid>` on the Proxmox host | `RDGEN_RUNNER_LINUX` = `rdgen-linux` |
| Windows: a Windows Server VM | `tools/runner-windows.ps1`, run in the VM (see below) | `RDGEN_RUNNER_WINDOWS` = `rdgen-windows` |
| Mac: an Intel or Apple Silicon Mac with Xcode | `tools/runner-mac.sh`, run on the Mac (see below) | `RDGEN_RUNNER_MACOS_X86_64` (Intel) or `RDGEN_RUNNER_MACOS_AARCH64` (Apple Silicon) = `rdgen-mac` |

Each setup asks for a **registration token**, which you get on GitHub from your build repo: **Settings → Actions → Runners → New self-hosted runner**. Pick the machine's OS and architecture, and copy only the value after `--token` in the commands it shows. A token lasts an hour. The scripts read it without showing it and never store it.

**Linux.** `runner-lxc.sh` creates an unprivileged LXC (4 cores, 8 GB RAM, 100 GB disk by default; `var_cores`, `var_ram`, `var_disk`, `var_ctid`, `var_net` change that) with Docker, which the Linux build runs in, and registers the runner. Use the CT for nothing else, because every Linux build clears its Docker images. In rdgen's form choose **Linux builds: x86_64 only**, because an x86_64 machine can't build the ARM clients, and preferably **Linux packages: .deb and .rpm only**. RustDesk 1.5.0's extra DRM build (an unattended .deb for Wayland desktops) runs on this runner only when you add the repository variable `RDGEN_LINUX_DRM` = `true`, because it occupies the runner for most of an hour.

**Windows.** Copy `tools/runner-windows.ps1` into the VM and run, in an administrator PowerShell, `powershell -ExecutionPolicy Bypass -File runner-windows.ps1 -Repo <owner>/<build repo>`. It installs what GitHub's Windows machines bring: Visual Studio 2022 Build Tools, Git, PowerShell 7, Python, .NET, NuGet and a few small tools, through Chocolatey. It creates a local administrator `rdgen-runner` for the runner service and registers the runner. Reboot if it asks to. Builds run upstream code as an administrator, so use a VM that does nothing else; it refuses to run on a domain controller. Plan for about 60 GB free.

**Mac.** On the Mac, under the account that will run the builds:
1. Install Xcode 16.4, the version GitHub's Mac machines build with. Download it from [developer.apple.com/download/all](https://developer.apple.com/download/all/) with your Apple ID (or take it from the App Store if it offers 16.x), put it in Applications and open it once. Then run `sudo xcode-select -s /Applications/Xcode.app` and `sudo xcodebuild -license accept`.
2. Copy `tools/runner-mac.sh` to the Mac and run `bash runner-mac.sh --repo <owner>/<build repo>` in Terminal. It installs the runner and everything else the build uses into `~/actions-runner` (about 1.2 GB): conda-forge's prebuilt Python, Ruby, CMake, Ninja, wget, jq, pkg-config and ImageMagick, CocoaPods, potrace and create-dmg built from their release sources, and Rust. It needs neither Homebrew nor `sudo` and leaves your shell profile alone, and deleting `~/actions-runner` removes all of it. With `--no-register` it installs everything before Xcode is ready; register later with `--register`.
3. Keep that account logged in, the Mac awake and about 40 GB free. The runner is a LaunchAgent, so it runs only while you're logged in.
4. In rdgen's form, set **Mac builds** to that kind of Mac.

Homebrew no longer has prebuilt packages for Intel Macs: there its installs would compile LLVM, GCC and Ruby for hours. So the workflow runs its `brew install` steps on GitHub's Macs only, and on yours it checks for Xcode and the tools above instead. An Intel Mac can't build Apple Silicon clients with this workflow. Intel clients do run on Apple Silicon Macs through Rosetta 2, which Apple supports in full through macOS 27.

On every self-hosted runner, the workflows first check the machine's prerequisites. They also skip the steps that only make sense on GitHub's throwaway machines: removing preinstalled toolchains to free disk, and adding swap. The first build on a new machine compiles every dependency and is slow; later builds reuse caches. Unlike GitHub's machines, yours keep their state from one job to the next, so the setup scripts and workflows clean up after Docker's root-owned files and keep Flutter's SDK patch from being applied twice. If a build fails, its run on GitHub shows the step.

## When clients don't show up
- **Clients never appear under Devices, or show no status.** A client checks in at its API server (the console URL when it was built). Run `rustdesk-config --check`. If it reports that the URL redirects, for example `http://` to `https://` behind Cloudflare, set the `https://` URL with `rustdesk-config`, then rebuild and reinstall the clients: a client can't follow that redirect, and Incoming Only builds don't let anyone change their API server.
- **New devices land under Devices → Pending** when *Require device approval* is on in CortenDesk's settings. Approve them there.
- **Devices you added by hand stay offline.** Enter the ID without spaces (the client shows `123 456 789`, but checks in as `123456789`). A device in the Recycle Bin ignores its client's check-ins until you restore it or delete it for good.
- **Clients can't log in ("RequestException, statusCode: 403").** If Cloudflare Access protects the console's web login through a tunnel route with a path, anchor that path: `^/login`. A tunnel path is a pattern that matches anywhere in the URL, so `login` also catches the clients' `/api/login` and `/api/login-options`, and the clients can't sign in to Access.
- **The web client stops with "websocket error before open: ws://…".** The console URL is `http://` while the browser has the page over `https://`, and browsers block that. Set the `https://` console URL with `rustdesk-config`.

## Unattended access
For a computer you want to reach without anyone there, build its client with Connection Type *Incoming Only* (or *Bidirectional*) and approve mode *Accept sessions via password*, then give it a permanent password in one of two ways:
- **In the build**: fill in *Set Permanent Password*. Every computer that installs it gets that password, so the installer stays off the public downloads page.
- **On each computer**: leave the password empty, and under Other add `allow-command-line-settings-when-settings-disabled=Y` to the override settings (it lets an administrator change settings from the command line even with *Disable Settings* on). After installing, set that computer's own password as root or administrator: on Linux `read -rs -p 'Password: ' PW; echo; sudo <client> --password "$PW"; unset PW`, on Windows `"C:\Program Files\<client>\<client>.exe" --password <password>` in an administrator prompt. The installer holds no password, so it can go on the public downloads page.

Whoever connects types that password instead of the one-time password, and nobody has to click Accept.

Hiding or encrypting the password inside the installer can't make a password build safe to publish. The client has to read the password on its own, with nobody typing anything. So whatever it needs to read it ships in the same file, and anyone with the file can do the same. RustDesk's login check also works with a hash of the password, so storing a hash would be just as good as the password itself. That's why the password has to come from somewhere other than the file, as in the per-computer option above. A password in the build for the computer you connect *from* does nothing for this. RustDesk never shows the permanent password in its window; it's stored readably in the client's settings file, which is why such builds stay off the public downloads page. On a Linux or Windows client that's already installed, an administrator can also set one with `<client> --password` (Linux: `sudo`), unless the build has *Disable Settings* on: then RustDesk answers "Settings are disabled!" and only a rebuild helps.

## Updates
`rustdesk-update` checks all three components, and each has its own backup, health check and automatic rollback.

The RustDesk server comes from its GitHub release, and the download is checked against the SHA-256 that GitHub records for it. The key and peer DB are backed up first. The health check covers the ports and the KeyExchange handshake.

CortenDesk comes from its GitHub release tag, followed by composer. The new version is staged while the old one keeps running. Then the updater enables maintenance mode, backs up the SQLite DB with `VACUUM INTO`, swaps the code, runs the migrations and restarts PHP. The health check covers `/up`, `/api/version` and `/login`, and a failure restores the old code and the pre-migration DB.

rdgen is rebuilt by `rdgenbuild` on the newest upstream master plus the patches, pushed to your build repo, and then deployed locally. If the patches no longer apply, nothing changes and you get one warning. This needs the stored install token, or a run of `rdgen-update --token-stdin`.

Backups go to `/var/backups/rustdesk` (root-only), which keeps the last 7. Notifications report the start, success or failure of a run with before→after versions. In `/etc/rustdesk-update.env`, `UPDATE_SERVER=0`, `UPDATE_CORTENDESK=0` or `UPDATE_RDGEN=0` skips a component, and `NOTIFY_UPTODATE=0` silences the daily "no updates" message.

The daily job does not upgrade OS packages; run `update` for those.

### Keeping the rdgen patches current
Upstream rdgen changes often, and now and then a change stops the patches from applying (the daily update then keeps the current version and warns you). If this repository lives on GitHub, `.github/workflows/rdgen-upstream.yml` fixes that for you:
- The CT starts it when its daily update finds that the patches stop applying (or fail the tests), see below; you can also start it with "Run workflow". It moves `rdgen/patches` to the newest upstream rdgen with `tools/rdgen-rebase.py` and checks the result the way a CT would: the patches apply, the CT's update path passes, the test suite passes, and actionlint finds nothing new. (It has no schedule: GitHub skipped the cron runs of this private repository.)
- When everything passes, it opens a pull request and merges it right away: nothing in it was edited by a person or by Claude, and the CT already runs the newest upstream with these patches. When a patch conflicts or a check fails, Claude Code repairs the series in a read-only job, the tool checks the repair again on its own, and you get a **draft** pull request that explains every decision. Repairs never merge by themselves; review them with care, they touch rdgen's hardening.
- One-time setup in the repository: add the secret `CLAUDE_CODE_OAUTH_TOKEN` (run `claude setup-token` on any machine with Claude Code; runs count against your Claude plan), and enable Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests". A clean run takes about 3 minutes of Actions time, a repair about 6 to 10.

A CT can follow the merged patches by itself:
```bash
rdgen-setup --patch-source <owner>/<repo>      # prints a deploy key: add it to the repository READ-ONLY
rdgen-setup --patch-source dispatch-token       # lets the CT start the repair workflow (token below, on stdin)
rdgen-setup --patch-source status               # or: off
```
The dispatch token is a fine-grained token for that repository only with Actions: Read and write; it is stored root-only in the CT and only ever used to start `rdgen-upstream.yml` once per upstream commit that breaks the patches. The update notification then says "repair requested" (or why not).
Its daily update then fetches `rdgen/patches` from the default branch over SSH (`github.com`, pinned host keys). A new series is checked (only patch files, a matching MANIFEST), built, tested and pushed like an upstream update, and replaces the installed patches only after that worked. The version in notifications then reads `<upstream>+<series commit>`. Changes to the tools themselves (`src/files`) still need `tools/refresh-ct.sh`.

## Notifications
`rustdesk-notify` sends the updater's messages and rdgen's results. It runs as root, and its settings (`/etc/rustdesk-update.env`, `/etc/rustdesk-apprise.conf`) are root-only, so the console never sees your webhook. Change them with `rustdesk-notify setup`.

CortenDesk has its own alerts under **Settings → Notifications**: devices waiting for approval, failed console logins, security alarms, repeated connection failures, and devices going offline or coming back. CortenDesk can only send them to an Apprise API server, so:
- With an Apprise API server, CortenDesk sends to it directly.
- With Discord or Apprise, CortenDesk sends to a small relay inside the CT, which it treats as an Apprise API server. The relay listens on `127.0.0.1:8296` only and needs a key. It queues each alert, and `cortendesk-alerts` passes the queue to `rustdesk-notify` every minute (Alpine) or every 15 seconds (Debian). If sending fails, it keeps trying for an hour. Mentions like `@everyone` in an alert can't ping anyone.

Setup switches on approvals, failed logins, security alarms and connection failures. Device offline/online stays off, because it fires whenever a client PC shuts down; turn it on under Settings → Notifications, for all devices or chosen ones, and set the cooldown there. If you point CortenDesk at an Apprise API server there yourself, it stays that way; `cortendesk-alerts connect` switches it back. The console's delivery log shows an alert as sent once the relay has queued it. Problems after that are logged in `/var/log/cortendesk-alerts.log` (Alpine) or by `journalctl -u cortendesk-alerts` (Debian).

## Privacy and outbound connections
CortenDesk's update badge fetches `raw.githubusercontent.com/marcpope/cortendesk/main/VERSION` (no payload, cached for 6 hours). OIDC, SMTP and Apprise connect only if you configure them.

cortendesk-server has no version check. Official hbbs contacts `api.rustdesk.com` daily for one.

rdgen talks to:
- `api.github.com` for your repo, plus the GitHub artifact storage host that artifact downloads redirect to
- `github.com` for git push and pull
- `pypi.org` and `files.pythonhosted.org` for pyzipper (hash-pinned), at install and update
- `github.com` over SSH (port 22) for your patch source, only if you set one (`rdgen-setup --patch-source`)

Your browser also loads Font Awesome (cdnjs) and a Google font on rdgen's page.

Installs and updates reach `github.com`, `api.github.com` (release digests), `raw.githubusercontent.com`, `getcomposer.org` and the distro mirrors (on Debian, also trixie-backports for rdgen). Notifications go only to the service you configure (Discord, your Apprise targets, or your Apprise API). The community-scripts framework may ask whether to send anonymous install diagnostics.

## Layout
- Server: `/opt/rustdesk-server` (hbbs, hbbr, cortendesk-utils), `/var/lib/rustdesk-server` (`id_ed25519*`, peer DB), `/etc/rustdesk-server/hbbs.conf`
- Console: `/opt/cortendesk` (code, with the previous release at `.prev`), `/var/lib/cortendesk` (SQLite, storage, downloads), `/etc/cortendesk/cortendesk.env` (APP_KEY and secrets)
- rdgen: `/opt/rdgen` (root-owned code), `/var/lib/rdgen` (DB and builds, user `rdgen`), `/var/lib/rdgen-build` (the patched git tree, bootstrap state and the optional install token; user `rdgenbuild`, mode 0700), `/etc/rdgen/` (`rdgen.env`, `server.pub`)
- Tools: `/usr/local/bin/{rustdesk-update,rustdesk-server-update,cortendesk-update,rdgen-update,rustdesk-admin,rustdesk-config,rustdesk-notify,cortendesk-alerts,rdgen-setup,rdgen-publish}`
- Alert relay: `/etc/nginx/rustdesk-alert-relay.conf`, `/usr/local/lib/cortendesk/alert-relay.php`, `/etc/cortendesk/alert-relay.key`, queue `/var/spool/cortendesk-alerts`

## Updating an existing CT to a newer version of this repo
The daily `rustdesk-update` updates the RustDesk server, CortenDesk and rdgen, but not this repo's own tools. To bring a CT up to a newer checkout without reinstalling, run this on the Proxmox host:
```bash
bash rustdesk-cortendesk-pve-stable/tools/refresh-ct.sh <ctid>
```
It copies the tools and rdgen patches into the CT and rebuilds rdgen from them. It also adds what newer versions need on the console (the `/clients/` and `/share/` links, the alert relay). Data, logins, keys and tokens stay.

Your build repo needs the same rdgen. If you kept the install token at setup, the refresh pushes the rebuilt rdgen there with it (`rdgen-setup --push`), so there's nothing else to do. The rebuild starts from the upstream rdgen these patches were tested on, which can be older than what the daily update had installed, so the refresh then runs `rdgen-update` to move both to the newest upstream rdgen the patches apply to. Without a stored token, run `rdgen-setup --github` in the CT afterwards and give it a token. Fine-grained tokens expire, so when the push reports a refused token, create a new one and run `rdgen-setup --github`.

## Development
Edit `src/install.tmpl` and `src/files/**` (each file installs at the same path in the CT), then run `bash build.sh`. It embeds `src/files` into `install/rustdesk-cortendesk-install.sh`, which has to stay under 120 KB because the framework passes it to `bash -c` as a single argument. The host script copies `rdgen/patches/`, `rdgen/patch-source` and `rdgen/github_known_hosts` into the CT separately.

To move the rdgen patches to a newer upstream by hand: `python3 tools/rdgen-rebase.py start` (then, after a conflict, resolve it in `.rdgen-work/rdgen`, `git rebase --continue`, and `python3 tools/rdgen-rebase.py finish`). It runs upstream code, so use a throwaway machine.

In a fork, set `_CS_DEFAULT_URL` at the top of `ct/rustdesk-cortendesk.sh` to your repo's raw URL, so curl one-liners fetch your files.

## Credits and licenses
This repo is licensed under the GNU GPL, version 3 or later (see LICENSE). It builds on MIT-licensed community-scripts code, whose notice is kept in NOTICE. The scripts and the software they install come from these projects:

- [RustDesk](https://github.com/rustdesk/rustdesk-server) by the RustDesk team: the official server (hbbs/hbbr) that cortendesk-server is based on. AGPL-3.0.
- [CortenDesk](https://github.com/marcpope/cortendesk) and [cortendesk-server](https://github.com/marcpope/cortendesk-server) by marcpope: the console and the server build with KeyExchange. AGPL-3.0.
- [rdgen](https://github.com/bryangerlach/rdgen) by bryangerlach: the custom client generator, which our patches in `rdgen/patches/` modify. GPL-3.0.
- [AllenMGu/rdgen](https://github.com/AllenMGu/rdgen) by AllenMGu: the artifact poller in patch 0005 is adapted from its `github_artifacts.py`. GPL-3.0.
- [community-scripts](https://github.com/community-scripts/ProxmoxVE): the framework this installer runs on, and the `rustdeskserver` script by tremor021 that it started from (Copyright (c) 2021-2026 community-scripts ORG). MIT.
- [Apprise](https://github.com/caronc/apprise) by caronc: the optional notification backend. BSD-2-Clause.
