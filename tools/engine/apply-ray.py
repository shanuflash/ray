#!/usr/bin/env python3
"""Puts Ray's own engine changes on top of the renamed Ardia engine (tools/engine/rename-ardia.py), from `engine-ray/`:
  - drop-patches.txt: series patches Ray leaves out (PLAN.md section 6's patch review). Their lines leave
    `patches/series` and their files are deleted.
  - remove-files.txt: other engine files Ray leaves out (the code that only served a dropped patch).
  - fixups/*.patch, in name order: unified diffs against the engine directory (`patch -p1`, no fuzz), each one
    concern, for the few edits a drop needs elsewhere.
Lines starting with # and blank lines are ignored. Everything is checked before anything is written: a listed
patch or file that isn't there, or a fixup that doesn't apply cleanly, stops the run with a message naming it.

Usage: apply-ray.py <engine dir> <engine-ray dir>
"""
import pathlib
import subprocess
import sys


def entries(path: pathlib.Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith('#')]


def fail(message: str) -> int:
    print(f'apply-ray: {message}', file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    engine = pathlib.Path(sys.argv[1]).resolve()
    ray = pathlib.Path(sys.argv[2]).resolve()
    series_path = engine / 'patches' / 'series'
    series = series_path.read_text().splitlines()

    drops = entries(ray / 'drop-patches.txt')
    for name in drops:
        if f'chromium {name}' not in series:
            return fail(f'drop-patches.txt names {name}, which patches/series doesn\'t have')
        if not (engine / 'patches' / name).is_file():
            return fail(f'drop-patches.txt names {name}, which isn\'t in patches/')
    removals = entries(ray / 'remove-files.txt')
    for name in removals:
        if not (engine / name).is_file():
            return fail(f'remove-files.txt names {name}, which isn\'t in the engine')

    series_path.write_text('\n'.join(line for line in series if line.removeprefix('chromium ') not in drops) + '\n')
    for name in drops:
        (engine / 'patches' / name).unlink()
    for name in removals:
        (engine / name).unlink()

    for fixup in sorted((ray / 'fixups').glob('*.patch')):
        dry = subprocess.run(['patch', '-p1', '--dry-run', '-F0', '-s', '-i', str(fixup)], cwd=engine,
                             capture_output=True, text=True)
        if dry.returncode != 0:
            return fail(f'{fixup.name} doesn\'t apply cleanly:\n{dry.stdout}{dry.stderr}')
        subprocess.run(['patch', '-p1', '-F0', '-s', '--no-backup-if-mismatch', '-i', str(fixup)], cwd=engine,
                       check=True)
    print(f'apply-ray: dropped {len(drops)} patches, removed {len(removals)} files, '
          f'applied {len(list((ray / "fixups").glob("*.patch")))} fixups')
    return 0


if __name__ == '__main__':
    sys.exit(main())
