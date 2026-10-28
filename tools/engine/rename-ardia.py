#!/usr/bin/env python3
"""Ray's engine is Ardia's, renamed. This writes Ray's `engine/` from an Ardia checkout's `engine/`, deterministically,
so a later Ardia commit can be run through it and its changes cherry-picked (PLAN.md section 6).

The rename map, applied to every path component and every text file:
  - Ardia's links: github.com/mantrakp04/ardia and ardia.dev become github.com/shanuflash/ray;
  - the bundle id com.ardia.browser becomes dev.shanus.ray, and Ardia's Apple team id is dropped (Ray has none yet);
  - then case by case: ArdiaCore -> RayCore, ARDIACORE -> RAYCORE, ardiacore -> raycore, Ardia -> Ray,
    ARDIA -> RAY, ardia -> ray. That covers the framework (RayCore), //ray/core, chrome/browser/ray, the g_ray_*
    hooks, the ray:// scheme, ray_namesub.py (Helium -> Ray in the engine's strings) and the keychain item
    "Ray Safe Storage" (account "Ray").
The engine's C calls keep their `ac_` names, which Ray's host already uses.

Binary files are copied unchanged. The output directory is replaced as a whole: never edit `engine/` by hand; Ray's own
changes live in `engine-ray/` and go on top (tools/engine/apply-ray.py).

Usage: rename-ardia.py <ardia checkout> <output engine dir>
"""
import pathlib
import re
import shutil
import sys

LINKS = [
    ('https://github.com/mantrakp04/ardia', 'https://github.com/shanuflash/ray'),
    ('github.com/mantrakp04/ardia', 'github.com/shanuflash/ray'),
    ('mantrakp04/ardia', 'shanuflash/ray'),
    ('https://ardia.dev', 'https://github.com/shanuflash/ray'),
    ('ardia.dev', 'github.com/shanuflash/ray'),
    ('com.ardia.browser', 'dev.shanus.ray'),
    ('MAC_TEAM_ID=U5L5T3NGVV', 'MAC_TEAM_ID=0000000000'),
    ('U5L5T3NGVV', '0000000000'),
]
NAMES = [
    ('ArdiaCore', 'RayCore'),
    ('ARDIACORE', 'RAYCORE'),
    ('ardiacore', 'raycore'),
    ('Ardia', 'Ray'),
    ('ARDIA', 'RAY'),
    ('ardia', 'ray'),
]
NAME_PATTERN = re.compile('|'.join(re.escape(old) for old, _ in NAMES))
NAME_MAP = dict(NAMES)


def rename_text(text: str) -> str:
    for old, new in LINKS:
        text = text.replace(old, new)
    return NAME_PATTERN.sub(lambda m: NAME_MAP[m.group(0)], text)


def is_text(data: bytes) -> bool:
    if b'\0' in data:
        return False
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    source = pathlib.Path(sys.argv[1]) / 'engine'
    target = pathlib.Path(sys.argv[2])
    if not (source / 'patches' / 'series').is_file():
        print(f'rename-ardia: {source} is not an Ardia engine directory', file=sys.stderr)
        return 64
    if target.exists():
        shutil.rmtree(target)
    files = 0
    for path in sorted(source.rglob('*')):
        if path.is_dir():
            continue
        relative = path.relative_to(source)
        out = target / pathlib.Path(*(rename_text(part) for part in relative.parts))
        out.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_bytes()
        if is_text(data):
            out.write_bytes(rename_text(data.decode('utf-8')).encode('utf-8'))
        else:
            out.write_bytes(data)
        shutil.copymode(path, out)
        files += 1
    leftovers = [str(p) for p in target.rglob('*') if p.is_file() and is_text(p.read_bytes())
                 and re.search(r'ardia', p.read_text(), re.I)]
    if leftovers:
        print('rename-ardia: still says ardia:\n  ' + '\n  '.join(leftovers), file=sys.stderr)
        return 1
    print(f'rename-ardia: {files} files from {source} into {target}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
