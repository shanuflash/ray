#!/usr/bin/env python3 -I
"""Per-process counters for the perf harness: proc_pid_rusage (CPU ns, idle and interrupt wakeups, footprint).
   perf-rusage.py <pid> …  → one JSON line: {pid: {cpu, idle, intr, footprint, resident}}; gone pids are left out."""
import ctypes, json, sys

lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = Timebase()
lib.mach_timebase_info(ctypes.byref(tb))
buf = ctypes.create_string_buffer(512)
out = {}
for arg in sys.argv[1:]:
    pid = int(arg)
    if lib.proc_pid_rusage(pid, 4, buf) != 0:
        continue
    u = lambda off: int.from_bytes(buf.raw[off:off + 8], "little")
    ticks = lambda v: v * tb.numer // tb.denom
    out[pid] = {"cpu": ticks(u(16)) + ticks(u(24)), "idle": u(32), "intr": u(40), "resident": u(64), "footprint": u(72)}
print(json.dumps(out))
