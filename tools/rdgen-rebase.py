#!/usr/bin/env python3
"""rdgen-rebase.py: move the rdgen patch series (rdgen/patches) to a newer upstream rdgen commit.

The daily workflow .github/workflows/rdgen-upstream.yml runs it; it works the same by hand.

  check                 print {"base", "latest", "moved"} as JSON
  start [--onto SHA]    rebase the series onto SHA (default: upstream master) in WORK/rdgen. The patch with the
                        "Rdgen-Mechanical: pullify" trailer (0009) is never rebased: an exec step regenerates it
                        with tools/pullify.py right after 0008. A clean rebase continues with finish.
  regen                 regenerate that patch at the current HEAD (after fixing pullify in 0008 when the exec step
                        stopped), then `git rebase --continue` in WORK/rdgen
  finish                after the rebase completed: export it into rdgen/patches, move UPSTREAM's base-commit,
                        rebuild MANIFEST (build.sh), then verify
  verify                check rdgen/patches against UPSTREAM's base the way the CT's daily update does: git am
                        (same tree as WORK's rebase, if any), the bootstrap's update as a dry run (compileall,
                        pullify --check, manage.py check, migrations, the test suite), and actionlint compared
                        with the previous series when actionlint is on PATH

Exit: 0 nothing to do / verified, 10 rebased and verified (rdgen/patches changed), 20 a patch conflicts (the rebase
stopped in WORK/rdgen), 21 pullify refused the new upstream workflows, 30 verification failed, 2 usage/state error
(status "older": the target is an ancestor of the base, refused without --allow-older).
WORK (--work, default .rdgen-work in this repository) keeps the clone and state.json between the steps;
WORK/report.md says what happened. Upstream code runs here (pullify, the tests): use a throwaway machine or runner.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'rdgen' / 'patches'
UPSTREAM_FILE = PATCHES / 'UPSTREAM'
MECHANICAL = 'Rdgen-Mechanical: pullify'
SHA = re.compile(r'[0-9a-f]{40}')


class Stop(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def run(cmd, cwd=None, check=True, env=None, capture=True):
    r = subprocess.run(cmd, cwd=cwd, text=True, capture_output=capture, env=env)
    if check and r.returncode != 0:
        out = ((r.stdout or '') + (r.stderr or '')).strip()
        raise Stop(30, f'{" ".join(str(c) for c in cmd[:4])} failed: {out[-1500:]}')
    return r


def git(*args, cwd, check=True):
    return run(['git', *args], cwd=cwd, check=check)


def upstream_info():
    text = UPSTREAM_FILE.read_text(encoding='utf-8')
    url = re.search(r'^upstream: (\S+)', text, re.M)
    base = re.search(r'^base-commit: ([0-9a-f]{40})\b', text, re.M)
    if not url or not base:
        raise Stop(2, f'{UPSTREAM_FILE} has no upstream: or base-commit: line')
    return url.group(1), base.group(1), text


def patch_files():
    files = sorted(PATCHES.glob('[0-9][0-9][0-9][0-9]-*.patch'))
    if not files:
        raise Stop(2, f'no patches in {PATCHES}')
    return files


def committer_env():
    """git am/rebase need a committer; reuse the series' author (the committer never reaches the patches)."""
    m = re.search(r'^From: (.+?) <([^>]+)>$', patch_files()[0].read_text(encoding='utf-8', errors='replace'), re.M)
    name, email = (m.group(1), m.group(2)) if m else ('rdgen-rebase', 'rdgen-rebase@localhost')
    return {'GIT_COMMITTER_NAME': name, 'GIT_COMMITTER_EMAIL': email}


class Work:
    def __init__(self, path):
        self.path = Path(path).resolve()
        self.repo = self.path / 'rdgen'
        self.state_file = self.path / 'state.json'
        self.report_file = self.path / 'report.md'

    def state(self):
        try:
            return json.loads(self.state_file.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            return {}

    def save(self, **kv):
        self.path.mkdir(parents=True, exist_ok=True)
        s = self.state()
        s.update(kv)
        self.state_file.write_text(json.dumps(s, indent=2) + '\n', encoding='utf-8')

    def report(self, title, body):
        self.path.mkdir(parents=True, exist_ok=True)
        self.report_file.write_text(f'# {title}\n\n{body.strip()}\n', encoding='utf-8')

    def clone(self, url):
        if not (self.repo / '.git').is_dir():
            self.path.mkdir(parents=True, exist_ok=True)
            git('clone', '--quiet', url, str(self.repo), cwd=self.path)
        git('fetch', '--quiet', url, '+refs/heads/master:refs/remotes/origin/master', cwd=self.repo)


def latest_master(url):
    r = run(['git', 'ls-remote', url, 'refs/heads/master'])
    sha = r.stdout.split()[0] if r.stdout.strip() else ''
    if not SHA.fullmatch(sha):
        raise Stop(2, f'cannot read master of {url}')
    return sha


def rebase_dir(repo):
    for name in ('rebase-merge', 'rebase-apply'):
        p = repo / '.git' / name
        if p.is_dir():
            return p
    return None


def cmd_check(args):
    url, base, _ = upstream_info()
    latest = latest_master(url)
    print(json.dumps({'base': base, 'latest': latest, 'moved': latest != base}))
    return 0


def cmd_start(args):
    url, base, _ = upstream_info()
    work = Work(args.work)
    target = args.onto or latest_master(url)
    if target == base:
        print(json.dumps({'status': 'current', 'base': base}))
        return 0
    work.clone(url)
    repo, env = work.repo, dict(os.environ, **committer_env())
    # commits made here by hand (or by the repair agent) carry the series' author, like the patches
    git('config', 'user.name', env['GIT_COMMITTER_NAME'], cwd=repo)
    git('config', 'user.email', env['GIT_COMMITTER_EMAIL'], cwd=repo)
    if rebase_dir(repo):
        git('rebase', '--abort', cwd=repo, check=False)
    git('am', '--abort', cwd=repo, check=False)
    target = git('rev-parse', '--verify', f'{target}^{{commit}}', cwd=repo).stdout.strip()
    if target == base:
        print(json.dumps({'status': 'current', 'base': base}))
        return 0
    if not args.allow_older and git('merge-base', '--is-ancestor', target, base, cwd=repo, check=False).returncode == 0:
        work.report('rdgen rebase refused', f'{target} is older than the base {base} (an ancestor of it): '
                    'that would roll upstream back, not update it. --allow-older does it anyway (tests).')
        print(json.dumps({'status': 'older', 'base': base, 'target': target}))
        return 2
    # the current series on its own base (this also puts every pre-image blob into the object store)
    git('checkout', '--quiet', '--force', '-B', 'rdgen-old', base, cwd=repo)
    git('clean', '-fdxq', cwd=repo)
    r = run(['git', 'am', '--quiet', '--keep-cr', *map(str, patch_files())], cwd=repo, check=False, env=env)
    if r.returncode != 0:
        git('am', '--abort', cwd=repo, check=False)
        raise Stop(30, f'the series does not apply to its own base {base[:12]}: {(r.stdout + r.stderr).strip()[-800:]}')
    mech = [c for c in git('rev-list', '--reverse', f'{base}..rdgen-old', cwd=repo).stdout.split()
            if re.search(r'^' + re.escape(MECHANICAL) + r'\s*$', git('log', '-1', '--format=%B', c, cwd=repo).stdout, re.M)]
    if len(mech) != 1:
        raise Stop(2, f'expected one patch with the trailer "{MECHANICAL}", found {len(mech)}')
    work.save(base=base, target=target, mechanical=mech[0], upstream=url)
    git('checkout', '--quiet', '-B', 'rdgen-new', 'rdgen-old', cwd=repo)
    me = f'{shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))}'
    seq_env = dict(env, GIT_SEQUENCE_EDITOR=f'{me} --work {shlex.quote(str(work.path))} _todo',
                   GIT_EDITOR='true')
    r = run(['git', 'rebase', '-i', '--onto', target, base, 'rdgen-new'], cwd=repo, check=False, env=seq_env)
    if r.returncode != 0 or rebase_dir(repo):
        return stopped(work, target, (r.stdout + r.stderr).strip())
    return cmd_finish(args)


def cmd_todo(args):
    """GIT_SEQUENCE_EDITOR: replace the mechanical patch's pick with an exec that regenerates it."""
    work = Work(args.work)
    mech = work.state()['mechanical']
    path = Path(args.todo)
    out, hit = [], 0
    me = f'{shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))}'
    for line in path.read_text(encoding='utf-8').splitlines(keepends=True):
        m = re.match(r'^(?:pick|p) ([0-9a-f]{4,40})\b', line)
        if m and mech.startswith(m.group(1)):
            out.append(f'exec {me} --work {shlex.quote(str(work.path))} regen\n')
            hit += 1
        else:
            out.append(line)
    if hit != 1:
        sys.exit(f'rdgen-rebase: the todo list has {hit} picks of {mech[:12]}')
    path.write_text(''.join(out), encoding='utf-8')
    return 0


def cmd_regen(args):
    """Regenerate the mechanical patch with this tree's pullify at the current HEAD (run inside WORK/rdgen)."""
    work = Work(args.work)
    st = work.state()
    repo = work.repo
    r = run([sys.executable, 'tools/pullify.py', '.'], cwd=repo, check=False)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return 21
    git('add', '-A', '.github', cwd=repo)
    if git('diff', '--cached', '--quiet', cwd=repo, check=False).returncode == 0:
        print('rdgen-rebase: pullify changed nothing', file=sys.stderr)
        return 21
    run(['git', 'commit', '--quiet', '--no-verify', '-C', st['mechanical']], cwd=repo,
        env=dict(os.environ, **committer_env()))
    return 0


def stopped(work, target, output):
    repo = work.repo
    rb = rebase_dir(repo)
    done = (rb / 'done').read_text(encoding='utf-8').strip().splitlines() if rb and (rb / 'done').exists() else []
    last = done[-1] if done else ''
    status = git('status', '--short', cwd=repo, check=False).stdout
    conflicted = [ln[3:] for ln in status.splitlines() if ln[:2] in ('UU', 'AA', 'DU', 'UD', 'AU', 'UA', 'DD')]
    if last.startswith('exec'):
        code, what = 21, 'pullify refused the new upstream workflows (the exec step after 0008 failed)'
        nxt = ('Fix tools/pullify.py (HEAD is patch 0008: `git commit --amend` there), then run '
               '`python3 tools/rdgen-rebase.py regen` and `git -C WORK/rdgen rebase --continue`.')
    else:
        code, what = 20, f'a patch conflicts: {last}'
        nxt = ('Resolve the conflicts in WORK/rdgen, `git add` them, `git rebase --continue` (repeat), '
               'then `python3 tools/rdgen-rebase.py finish`.')
    body = (f'Target upstream: {target}\n\n{what}\n\nConflicted files:\n'
            + (''.join(f'- {f}\n' for f in conflicted) or '- (none)\n')
            + f'\nNext: {nxt}\n\nGit said:\n```\n{output[-3000:]}\n```\n')
    work.report('rdgen rebase stopped', body)
    print(json.dumps({'status': 'conflict' if code == 20 else 'pullify', 'target': target,
                      'step': last, 'files': conflicted}))
    return code


def cmd_finish(args):
    work = Work(args.work)
    st = work.state()
    repo = work.repo
    if not st.get('target') or not (repo / '.git').is_dir():
        raise Stop(2, 'nothing started: run start first')
    if rebase_dir(repo):
        raise Stop(2, 'the rebase is still in progress in ' + str(repo))
    target = st['target']
    count = int(git('rev-list', '--count', f'{target}..HEAD', cwd=repo).stdout)
    if git('merge-base', '--is-ancestor', target, 'HEAD', cwd=repo, check=False).returncode != 0 or count == 0:
        raise Stop(2, f'HEAD is not a series on top of {target[:12]}')
    tmp = Path(tempfile.mkdtemp(prefix='rdgen-export-'))
    try:
        # no signature: it would carry this machine's git version into every patch file
        git('format-patch', '--quiet', '--no-signature', f'{target}..HEAD', '-o', str(tmp), cwd=repo)
        for old in patch_files():
            old.unlink()
        for new in sorted(tmp.glob('*.patch')):
            shutil.copy2(new, PATCHES / new.name)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    date, subject = git('log', '-1', '--format=%ad%x00%s', '--date=short', target, cwd=repo).stdout.strip().split('\0', 1)
    _, _, text = upstream_info()
    subject = subject.replace('"', "'")[:80]
    text = re.sub(r'^base-commit: .*$', f'base-commit: {target} (master, {date}, "{subject}")', text, count=1, flags=re.M)
    text = re.sub(r'^patches: \d+', f'patches: {count}', text, count=1, flags=re.M)
    UPSTREAM_FILE.write_text(text, encoding='utf-8')
    if (ROOT / 'build.sh').exists():
        run(['bash', 'build.sh'], cwd=ROOT)   # MANIFEST (and the generated install script)
    code = cmd_verify(args)
    return 10 if code == 0 else code


def cmd_verify(args):
    url, base, _ = upstream_info()
    work = Work(args.work)
    work.clone(url)
    repo, env = work.repo, dict(os.environ, **committer_env())
    problems, notes = [], []
    if rebase_dir(repo):
        raise Stop(2, 'a rebase is in progress in ' + str(repo))
    git('am', '--abort', cwd=repo, check=False)
    git('checkout', '--quiet', '--force', '-B', 'rdgen-verify', base, cwd=repo)
    git('clean', '-fdxq', cwd=repo)
    r = run(['git', 'am', '--quiet', '--keep-cr', *map(str, patch_files())], cwd=repo, check=False, env=env)
    if r.returncode != 0:
        git('am', '--abort', cwd=repo, check=False)
        raise Stop(30, f'the patches do not apply to {base[:12]}: {(r.stdout + r.stderr).strip()[-800:]}')
    tree = git('rev-parse', 'HEAD^{tree}', cwd=repo).stdout.strip()
    st = work.state()
    if st.get('target') == base and git('rev-parse', '--verify', '-q', 'rdgen-new', cwd=repo, check=False).returncode == 0:
        if git('rev-parse', 'rdgen-new^{tree}', cwd=repo).stdout.strip() != tree:
            problems.append('git am of the exported patches does not give the rebased tree')
        else:
            notes.append('git am of the exported patches gives the rebased tree')
    # the CT's path: the bootstrap's update builds base + patches (0009 by pullify) and verifies, incl. the tests
    mirror = work.path / 'upstream.git'
    if not mirror.is_dir():
        git('init', '--quiet', '--bare', str(mirror), cwd=work.path)
    git('push', '--quiet', '--force', str(mirror), f'{base}:refs/heads/master', cwd=repo)
    src, statef = work.path / 'bootstrap-tree', work.path / 'bootstrap-state.json'
    shutil.rmtree(src, ignore_errors=True)
    statef.unlink(missing_ok=True)
    boot = [sys.executable, str(repo / 'tools' / 'rdgen-github-bootstrap'), '--env-file', os.devnull,
            '--owner', 'verify', '--repo', 'verify', '--state', str(statef), 'update', '--src', str(src),
            '--patches', str(PATCHES), '--upstream', mirror.as_uri(), '--python', sys.executable]
    # RDGEN_VERIFY_TESTS=0: the suite runs once, below, whether or not this series' bootstrap runs it too
    r = run(boot, cwd=work.path, check=False, env=dict(env, GIT_AUTHOR_NAME='verify', GIT_AUTHOR_EMAIL='verify@localhost',
                                                       RDGEN_VERIFY_TESTS='0'))
    last = (r.stdout.strip().splitlines() or [''])[-1]
    if r.returncode != 0 or '"dry run' not in last:
        problems.append(f'the bootstrap update (the CT\'s daily path) failed: {last[-1500:] or r.stderr.strip()[-1500:]}')
    elif git('rev-parse', 'HEAD^{tree}', cwd=src).stdout.strip() != tree:
        problems.append('the bootstrap update gives another tree than git am')
    else:
        notes.append('the bootstrap update (compileall, pullify --check, manage.py check, migrations) passes')
        data = Path(tempfile.mkdtemp(prefix='rdgen-test-'))
        try:
            r = run([sys.executable, 'manage.py', 'test', 'rdgenerator.tests', '--noinput'], cwd=src, check=False,
                    env=dict(env, SECRET_KEY=os.urandom(32).hex(), ZIP_PASSWORD=os.urandom(24).hex(),
                             RDGEN_DATA_DIR=str(data), RDGEN_ENV_FILE='', RDGEN_VERIFY_TESTS='0',
                             PYTHONDONTWRITEBYTECODE='1'))
        finally:
            shutil.rmtree(data, ignore_errors=True)
        out = r.stdout + r.stderr
        ran = re.search(r'^Ran (\d+) tests?', out, re.M)
        if r.returncode != 0:
            failed = [ln for ln in out.splitlines() if ln.startswith(('FAIL:', 'ERROR:'))]
            problems.append('the test suite failed:\n' + ('\n'.join(failed[:30]) or out.strip()[-1500:]))
        else:
            notes.append(f'the test suite passes ({ran.group(1) if ran else "?"} tests)')
    al = shutil.which('actionlint')
    if al:
        new = actionlint(al, repo, 'rdgen-verify')
        if git('rev-parse', '--verify', '-q', 'rdgen-old', cwd=repo, check=False).returncode == 0 and st.get('target') == base:
            added = sorted(new - actionlint(al, repo, 'rdgen-old'))
            if added:
                problems.append('actionlint: new findings:\n' + '\n'.join(added[:20]))
            else:
                notes.append(f'actionlint: no new findings ({len(new)} from upstream)')
        else:
            notes.append(f'actionlint: {len(new)} findings (no previous series to compare with)')
    body = (f'Base: {base}\n\n' + ''.join(f'- OK: {n}\n' for n in notes) + ''.join(f'- FAILED: {p}\n' for p in problems))
    work.report('rdgen verification ' + ('failed' if problems else 'passed'), body)
    print(json.dumps({'status': 'failed' if problems else 'verified', 'base': base, 'problems': problems}))
    return 30 if problems else 0


def actionlint(binary, repo, ref):
    """Findings for ref's workflows, without line numbers (they move with every upstream change)."""
    tmp = Path(tempfile.mkdtemp(prefix='rdgen-al-'))
    try:
        arch = subprocess.run(['git', 'archive', ref, '.github'], cwd=repo, capture_output=True, check=True)
        subprocess.run(['tar', '-x', '-C', str(tmp)], input=arch.stdout, check=True)
        files = sorted(str(p) for p in (tmp / '.github' / 'workflows').glob('*.yml'))
        r = subprocess.run([binary, '-no-color', '-oneline', '-shellcheck=', *files], cwd=tmp, capture_output=True, text=True)
        return {re.sub(r':\d+:\d+:', ':', ln.replace(str(tmp) + '/', '')) for ln in r.stdout.splitlines() if ln.strip()}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--work', default=str(ROOT / '.rdgen-work'))
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('check')
    p = sub.add_parser('start')
    p.add_argument('--onto', help='upstream commit (default: master)')
    p.add_argument('--allow-older', action='store_true', help='also move to a commit older than the base (tests)')
    sub.add_parser('regen')
    sub.add_parser('finish')
    sub.add_parser('verify')
    p = sub.add_parser('_todo')
    p.add_argument('todo')
    args = ap.parse_args(argv)
    handlers = {'check': cmd_check, 'start': cmd_start, 'regen': cmd_regen, 'finish': cmd_finish,
                'verify': cmd_verify, '_todo': cmd_todo}
    try:
        return handlers[args.cmd](args)
    except Stop as exc:
        Work(args.work).report(f'rdgen-rebase {args.cmd} stopped', str(exc))
        print(json.dumps({'status': 'error' if exc.code == 2 else 'failed', 'error': str(exc)[-2000:]}))
        return exc.code


if __name__ == '__main__':
    sys.exit(main())
