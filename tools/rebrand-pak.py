#!/usr/bin/env python3
"""Renames the browser in Chromium .pak string files: "Ardia" (the prebuilt engine's product name) to "Ray".

The engine's own pages (chrome://settings, extension prompts, …) take their wording from locale.pak. Pak v5:
  u32 version (5), u8 encoding, 3 pad, u16 resource count, u16 alias count,
  (u16 id, u32 offset) × (count + 1, the last a sentinel), (u16 id, u16 entry index) × aliases, then the data.
Only text resources (valid UTF-8, no NUL bytes) are touched, and only the capitalised name, so identifiers such as
`ardia_…` and URLs stay as they are.

  tools/rebrand-pak.py <file.pak>…
"""
import re
import struct
import sys

NAME = re.compile(rb"Ardia(?![a-z])")
NEW = b"Ray"


def rebrand(data: bytes) -> bytes | None:
    version, encoding = struct.unpack_from("<IB", data, 0)
    if version != 5:
        return None
    count, aliases = struct.unpack_from("<HH", data, 8)
    table = 12
    entries = [struct.unpack_from("<HI", data, table + 6 * i) for i in range(count + 1)]
    alias_bytes = data[table + 6 * (count + 1): table + 6 * (count + 1) + 4 * aliases]
    bodies = [data[entries[i][1]:entries[i + 1][1]] for i in range(count)]
    changed = False
    for i, body in enumerate(bodies):
        if b"Ardia" not in body or b"\0" in body:
            continue
        try:
            body.decode("utf-8")
        except UnicodeDecodeError:
            continue
        bodies[i] = NAME.sub(NEW, body)
        changed = changed or bodies[i] != body
    if not changed:
        return None
    start = table + 6 * (count + 1) + 4 * aliases
    out = bytearray(data[:table])
    offset = start
    for i in range(count):
        out += struct.pack("<HI", entries[i][0], offset)
        offset += len(bodies[i])
    out += struct.pack("<HI", entries[count][0], offset)
    out += alias_bytes
    for body in bodies:
        out += body
    return bytes(out)


def main() -> int:
    renamed = 0
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            data = f.read()
        result = rebrand(data)
        if result is None:
            continue
        with open(path, "wb") as f:
            f.write(result)
        renamed += 1
    print(f"rebranded {renamed} of {len(sys.argv) - 1} pak files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
