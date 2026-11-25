# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-11-25

**Upgrading:** nothing to do.

### Changed
- The rdgen patches now apply to upstream rdgen commit `5a461bea1483`.

## [0.2.0] - 2026-11-25
**Upgrading:** run `tools/refresh-ct.sh <ctid>` on the Proxmox host to get the new patch-source messages. The build repository's new README, CHANGELOG and NOTICE arrive with the next rdgen update. If a Mac of your own signs builds, add Apple's Developer ID G2 intermediate to its System keychain once; SETUP-PULL.md in the build repository has the command. If you added a public name for rdgen to `/etc/rdgen/rdgen.env` by hand, the refresh keeps it when `CSRF_TRUSTED_ORIGINS` is set to that name; otherwise run `rdgen-setup --public-url https://<name>` once. The refresh also gives the console's WebSocket bridge the proxies from `TRUSTED_PROXIES`, so it sees real client addresses.

### Added

- The RustDesk app can reach your server only through your tunnel or reverse proxy. With *Use WebSocket* on and the console's name as ID and relay server, it connects to `wss://<name>/ws/id` and `/ws/relay`, so no port forwards or DNS record need to point at your home IP. The README's "Only through your tunnel (WebSocket clients)" section covers the device settings, the rdgen Override lines and the order to switch devices in. `rustdesk-config --check` now tests `/ws/relay` as well as `/ws/id`.
- `rdgen-setup --public-url https://<name>` lets rdgen answer on a public name, such as one a Cloudflare Tunnel publishes behind Access, and points CortenDesk's Build Installers link there. Before, rdgen answered such a name with "Bad Request (400)", and adding the name by hand didn't last. The README's "Opening rdgen from outside your LAN" section covers the setup.
- `rustdesk-config --check` now also checks that the console builds `https://` links on every request. A proxy or tunnel connector that isn't in `TRUSTED_PROXIES` gets `http://` links, so Livewire actions on those pages fail as mixed content. With a Cloudflare Tunnel that has replicas, this happened only on the requests that went through an untrusted replica.
- rdgen's build repository now has its own README, CHANGELOG and NOTICE (patch 0034). The README says that every update replaces the repository, so nothing should be committed there by hand, and lists the secrets and variables the builds read. Until now, files added there by hand were lost at the next update.

### Fixed

- rdgen builds with *Use WebSocket* (`allow-websocket=Y` under Other) that kept the pre-filled Host never registered: the Host is the name with the port forwards, so the app reached the console's web page instead of `/ws/id` and said "ID does not exist", while the console listed the device as online. rdgen now also knows the console's host name (from `APP_URL`): a WebSocket build with an empty Host gets it, and its relay server too, and the form refuses the pre-filled name for a WebSocket build and the console's name for a normal one, saying which to use (patch 0038).
- rdgen builds with *Use WebSocket* that aren't Incoming Only never registered through a tunnel either, even with the right host: the app uses `wss://` only when its own API server setting starts with `https`, and rdgen put the API server into that setting only for Incoming Only builds, so the others connected with `ws://`, got a redirect to `https` they can't follow, and waited until someone typed the API server into the app by hand. WebSocket builds now carry their `https://` API server in that setting, and rdgen refuses a WebSocket build whose API server isn't `https://` when its host is a public name.
- GitHub no longer warns about Node 20 for rdgen's upload steps. Every build workflow uploaded its results with `actions/upload-artifact` v4, which runs on Node 20 (the setup job had even been pinned back from upstream's v7); they now use v7 (Node 24), like upstream's own steps. Three actions that upstream rdgen pins still run on older Node versions and still warn: `KyleMayes/install-llvm-action` (Windows builds; no Node 24 release exists yet), RustDesk's fork of `run-on-arch-action` (Linux builds) and `r0adkll/sign-android-release` (Android). Replacing those needs test builds.
- hbbs and hbbr saw every WebSocket connection (the browser client, and the app with *Use WebSocket* on) as coming from the reverse proxy or tunnel connector, so the console's connection log showed the proxy's address instead of the client's. nginx now passes on the client's address from `X-Forwarded-For`, and only for requests from the proxies in `TRUSTED_PROXIES`.
- `rustdesk-config` and `rdgen-setup` (also run by `tools/refresh-ct.sh`) no longer undo settings they don't own. They removed rdgen's public name from `ALLOWED_HOSTS`, so rdgen answered it with 400 again, and set CortenDesk's Build Installers link back to `http://<lxc-ip>:8190`, even over a link saved in Settings. They now keep rdgen's public name and a link saved in Settings, and `rustdesk-config` says so when it drops a name rdgen answered to.
- The proxy prompt in `rustdesk-config` now asks for all of a tunnel's connectors (`a,b` or a subnet). One connector of several left the rest untrusted.
- Linux builds with "X for offline" turned on work again, and so do Flatpak builds of app names that contain a hyphen. The rdgen patches now apply to upstream rdgen `b821812`; upstream fixed both in `cf4a5d2`. The build workflows use the newer major versions of the GitHub actions upstream moved to, each pinned to a commit.
- Signed macOS builds on a Mac of your own failed at signing with `errSecInternalComponent` when the runner runs as a LaunchDaemon, because codesign there looks for the certificate chain only in the System keychain. Before a signed build starts, the workflow now checks that Apple's Developer ID G2 intermediate is in that keychain and says how to add it. `tools/runner-mac.sh` prints the same command.
- Apple Silicon builds on a Mac with Xcode 27 failed because RustDesk's CocoaPods targets ask for macOS 10.13 and 10.14, and Xcode 27 builds nothing older than 12.0. With Xcode 27 or later, those builds now target macOS 12.0, so the clients need macOS 12 or later.
- Windows builds on a Windows Server Core runner came out as an .exe only, without the MSI. RustDesk's MSI script starts the client it packages to read its version and build date, and on Server Core the client can't start, because Server Core leaves out desktop DLLs that RustDesk links. The MSI now gets the version from Cargo.toml and the build date from the clock instead, and a build whose MSI fails now fails as a whole rather than finishing without it.
- Dependabot no longer opens pull requests in rdgen's build repository. The config came from upstream rdgen, and every update replaces that repository, so a merged bump was overwritten, and until then it left the workflows out of step with what the build expects. Action updates still arrive through upstream rdgen and the patch series, and Dependabot alerts stay on.
- The signing keychain is now removed even when signing fails, together with its entry in the runner's list of keychains. Before, every failed signed build left a keychain behind on the Mac.
- `rdgen-setup --patch-source status` and the daily update now say so when the branch they follow no longer exists, for example after the repository was renamed. They used to ask for the deploy key, which was already in place.

## [0.1.0] - 2026-11-15
**Upgrading:** nothing to do.

### Changed

- The public repository now changes once per version, as one commit per release. Before, every change was copied there as it landed. Installing from the `stable` branch still works the same way.
- The IP filter hint in rdgen's form now uses documentation addresses (`192.0.2.0/24,198.51.100.5`) as its example.
- The patches in `rdgen/patches` now name the release bot as their author, and their test fixtures use example names instead of real ones.
- CI test dependencies for rdgen moved to Django 6.1.3, Pillow 13.0.0 and certifi 2026.10.23, which fix the known vulnerabilities in the old versions.
- The README now has badges, a Why section, a quick start, a requirements table, a scope note, a table of where settings live, a list of known limits and a repo map, and no longer describes the old mirroring workflow.

### Fixed

- Old project names in the NOTICE file and in script headers now say rustdesk-cortendesk-pve.

[Unreleased]: https://github.com/rob-paprocki/rustdesk-cortendesk-pve/commits/stable
