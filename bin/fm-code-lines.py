#!/usr/bin/env python3
"""Check physical code lines, including blanks/comments, against a 1,000-line cap.

Run from a Git checkout: python3 bin/fm-code-lines.py [--root PATH].
Tracked and unignored new source files count. Generated source counts too.
.code-lines.json contains reviewed legacy ceilings; lower or remove an entry
when its file shrinks. There is deliberately no automatic baseline reset.
Exit 0: pass; 1: violations or unreadable input; 2: invalid arguments.
"""
import argparse
import json
import pathlib
import subprocess
import sys

EXTENSIONS = set('.sh .bash .zsh .py .go .ts .tsx .js .jsx .mjs .cjs .mts .cts .rs .rb .swift .c .h .cc .cpp .hpp .cs .java .kt .kts .php .vue .svelte .html .css .scss .sql .lua .ex .exs .erl .hs .pl .r .R .ps1'.split())
NAMES = {'Makefile', 'Dockerfile', 'Justfile'}
LIMIT = 1000


def check(root):
    baseline = json.loads((root / '.code-lines.json').read_text())
    if not isinstance(baseline, dict):
        raise ValueError('legacy ceilings must be a JSON object')
    for name, count in baseline.items():
        if pathlib.PurePosixPath(name).is_absolute() or '..' in pathlib.PurePosixPath(name).parts:
            raise ValueError('legacy path must stay inside the repository')
        if type(count) is not int or count <= LIMIT:
            raise ValueError('legacy ceilings must be integers greater than 1000')
    paths = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], check=True, capture_output=True).stdout.split(b'\0')
    seen, errors, checked = set(), [], 0
    for raw in sorted(set(paths)):
        if not raw:
            continue
        name = raw.decode('utf-8')
        path = root / name
        # A staged deletion is not a source file; symlinks must not read outside the checkout.
        if not path.exists() and not path.is_symlink():
            continue
        is_code = path.suffix in EXTENSIONS or path.name in NAMES
        if path.is_symlink():
            if not is_code:
                continue
            if not path.exists() or not path.resolve().is_relative_to(root):
                errors.append((name, 'source symlink must resolve inside the repository'))
                continue
        if not path.is_file():
            continue
        with path.open('rb') as source:
            first = source.readline()
            if not is_code and not (path.suffix == '' and first.startswith(b'#!')):
                continue
            count = int(bool(first)) + sum(1 for _ in source)
        checked += 1
        seen.add(name)
        ceiling = baseline.get(name, LIMIT)
        if count > ceiling:
            errors.append((name, f'{count} lines exceeds {ceiling}; split at a responsibility boundary'))
        elif name in baseline and count < ceiling:
            action = 'remove its legacy entry' if count <= LIMIT else f'lower its legacy ceiling to {count}'
            errors.append((name, action))
    errors.extend((name, 'remove the stale legacy entry') for name in baseline.keys() - seen)
    return checked, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path.cwd())
    args = parser.parse_args()
    try:
        checked, errors = check(args.root.resolve())
        print(f'checked: {checked}\nlimit: {LIMIT}\nviolations: {len(errors)}')
        for path, reason in errors:
            print('error: ' + json.dumps(f'{path}: {reason}'))
        return int(bool(errors))
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print('error: ' + json.dumps(str(exc)))
        print('help: "Run from a Git checkout containing the reviewed .code-lines.json file."')
        return 1


if __name__ == '__main__':
    sys.exit(main())
