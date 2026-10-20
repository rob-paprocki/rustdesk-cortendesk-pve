#!/usr/bin/env bash
# Renders install/rustdesk-cortendesk-install.sh from src/install.tmpl, embedding every file under src/files/
# (target path = path below src/files). The framework passes the install script to `bash -c` as ONE argument,
# which Linux caps at 128 KiB (MAX_ARG_STRLEN), so the result must stay well below that.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import os
MARK = "RDFILE_EOF"
parts = []
for root, _, files in sorted(os.walk("src/files")):
    for name in sorted(files):
        src = os.path.join(root, name)
        dst = "/" + os.path.relpath(src, "src/files")
        body = open(src).read()
        assert MARK not in body, f"{src} contains the heredoc marker"
        assert not body.endswith("\n\n"), f"{src} ends with a blank line"
        mode = "755" if "/bin/" in dst else "644"
        parts.append(f'  mkdir -p "{os.path.dirname(dst)}"\n'
                     f"  cat <<'{MARK}' >\"{dst}\"\n{body.rstrip(chr(10))}\n{MARK}\n"
                     f'  chmod {mode} "{dst}"')
tmpl = open("src/install.tmpl").read()
assert tmpl.count("@@FILES@@") == 1
out = tmpl.replace("@@FILES@@", "\n".join(parts))
assert "@@" not in out
size = len(out.encode())
assert size < 120_000, f"install script is {size} bytes; must stay below 120000 (bash -c argument limit)"
os.makedirs("install", exist_ok=True)
open("install/rustdesk-cortendesk-install.sh", "w").write(out)
print(f"built install/rustdesk-cortendesk-install.sh ({size} bytes, {len(parts)} embedded files)")
PY
(cd rdgen/patches && ls -1 UPSTREAM *.patch >MANIFEST)   # remote runs fetch the patches listed here
chmod +x install/rustdesk-cortendesk-install.sh ct/rustdesk-cortendesk.sh src/files/usr/local/bin/* 2>/dev/null || true
for f in ct/rustdesk-cortendesk.sh install/rustdesk-cortendesk-install.sh src/files/usr/local/bin/* src/files/usr/local/lib/rustdesk-cortendesk/*.sh; do
  [ -f "$f" ] && bash -n "$f"
done
if command -v php >/dev/null; then for f in src/files/usr/local/lib/cortendesk/*.php; do php -l "$f" >/dev/null; done; fi
