#!/usr/bin/env python3
"""Renames the browser in Chromium .pak files: "Ardia" (the prebuilt engine's product name) to "Ray" in strings, and
Ardia's logo images to Ray's icon.

The engine's own pages (chrome://settings, extension prompts, …) take their wording from locale.pak. Pak v5:
  u32 version (5), u8 encoding, 3 pad, u16 resource count, u16 alias count,
  (u16 id, u32 offset) × (count + 1, the last a sentinel), (u16 id, u16 entry index) × aliases, then the data.
Only text resources (valid UTF-8, no NUL bytes) are touched, and only the capitalised name, so identifiers such as
`ardia_…` and URLs stay as they are. Logo images are found by the SHA-256 of Ardia's product_logo*.png files and
replaced with `ray-<size>.png` from the logos folder, at the same pixel size.

  tools/rebrand-pak.py [--logos <folder>] <file.pak>…
"""
import hashlib
import os
import re
import struct
import sys

NAME = re.compile(rb"Ardia(?![a-z])")
NEW = b"Ray"
# SHA-256 of the engine's product_logo*.png files (Ardia's logo), as the prebuilt engine packs them.
ARDIA_LOGOS = {
    "1bd8805c33f93580c1d07233e92d8cd7c5aa97a4d1a13cd8dbef7777575c2048",
    "33340ef42f7e764025421d1c0e9df538c9bf9be36db77ea636e9d77ce20ddee5",
    "896d7475aaa8e6f0fbb9ee9c85914fb965712203369257178786410a082c5645",
    "a64998b4d359e542c12c7b440e3355d5f712918d91be22ba45c4d1664444e38b",
    "a6bcdce1cb422bd5b5e0e6e27783db8c49e75ef3789c88f90e3cdc649539e405",
    "d807114d8fec7d22049edc4df2c30dd0b15bd8f1452470446bbd376d2f84865c",
    "ea1b9b2e20af6be93be9786c88ee03097220802c8e66be18d34fc6daa4fa2f61",
    "f668c3e4cc1d86d8db4fbfbbaa9ad41b31b9d1eb5f7f9b8158a21bb65bfd8345",
    "fb69883caa40ffe6019851da51f0b8df7886c3e908cd877d9de65fbea1a42ea6",
}


def png_size(data: bytes) -> tuple[int, int] | None:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def split_pak(data: bytes):
    """A pak v5 file as (ids, bodies, alias bytes), or None for another version."""
    version, encoding = struct.unpack_from("<IB", data, 0)
    if version != 5:
        return None
    count, aliases = struct.unpack_from("<HH", data, 8)
    table = 12
    entries = [struct.unpack_from("<HI", data, table + 6 * i) for i in range(count + 1)]
    alias_bytes = data[table + 6 * (count + 1): table + 6 * (count + 1) + 4 * aliases]
    bodies = [data[entries[i][1]:entries[i + 1][1]] for i in range(count)]
    return [entries[i][0] for i in range(count)], entries[count][0], bodies, alias_bytes, data[:table]


def join_pak(header: bytes, ids: list, sentinel_id: int, bodies: list, alias_bytes: bytes) -> bytes:
    count = len(ids)
    out = bytearray(header)
    offset = len(header) + 6 * (count + 1) + len(alias_bytes)
    for i in range(count):
        out += struct.pack("<HI", ids[i], offset)
        offset += len(bodies[i])
    out += struct.pack("<HI", sentinel_id, offset)
    out += alias_bytes
    for body in bodies:
        out += body
    return bytes(out)


def rebrand(data: bytes, logos: str | None) -> bytes | None:
    parsed = split_pak(data)
    if parsed is None:
        return None
    ids, sentinel_id, bodies, alias_bytes, header = parsed
    changed = False
    for i, body in enumerate(bodies):
        if logos and hashlib.sha256(body).hexdigest() in ARDIA_LOGOS:
            size = png_size(body)
            replacement = os.path.join(logos, f"ray-{size[0]}.png") if size else ""
            if size and os.path.exists(replacement):
                bodies[i] = open(replacement, "rb").read()
                changed = True
            continue
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
    return join_pak(header, ids, sentinel_id, bodies, alias_bytes)


def main() -> int:
    args = sys.argv[1:]
    logos = None
    if args[:1] == ["--logos"]:
        logos, args = args[1], args[2:]
    renamed = 0
    for path in args:
        with open(path, "rb") as f:
            data = f.read()
        result = rebrand(data, logos)
        if result is None:
            continue
        with open(path, "wb") as f:
            f.write(result)
        renamed += 1
    print(f"rebranded {renamed} of {len(args)} pak files", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
