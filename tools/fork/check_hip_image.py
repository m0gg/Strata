#!/usr/bin/env python3
"""Check the AMD (HIP) binaries of a fork build: they are all there, and their CPU code is the x86-64 level asked for and no wider.

Run on the engine package (what packaging/build_hip_linux.sh writes), on the folder setup.py builds, or on the copy
inside a built image - tools/fork/build-hip.sh runs it on the package and on the image's own copy:

    python3 tools/fork/check_hip_image.py --engine /tmp/strata-hip-gfx1101-znver1/components/engine/<package> --march znver1

Why: the CPU kernels are native code. Upstream builds them portable (STRATA_PORTABLE=ON: the AVX2 baseline, which
runs on any AVX2 CPU), and a fork build adds -march=<level> so the image is tuned for one CPU and, more importantly,
so a wide build machine cannot put its own instructions into an image for a narrow PC. A GitHub runner is an AVX-512
Xeon; the PC this fork runs on is an AMD Zen 1 (Threadripper 1950X). An image that leaked AVX-512 stops with
`illegal instruction` (exit 132) on that PC - and the only cheap way to see it before the model is downloaded is to
read the machine code, which is what this does.

The rule is upstream's (tools/check_isa_guard.py): wide instructions are allowed only in functions that are reached
behind a CPU check - check_isa_guard.py's public wide kernels (s2_expert_*, iq256_*, nvfp4_512_*, ...), the AVX-512
files' own names, and anonymous-namespace functions, which only their own wide-ISA file reaches. Everything else in
the binary runs on every CPU, so it must stay at the level the image asked for.

Exit 0 = fine, 1 = a problem named on stderr, 77 = cannot check here (no objdump, not Linux).
"""
import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

# -march names whose level has AVX-512: an image built for one of them may hold the wider instructions, and runs
# only on a CPU that has them. Everything else (znver1, znver2, znver3, x86-64-v3, native) must not show any.
AVX512_MARCH = ("znver4", "zen4", "znver5", "skylake", "cascade", "icelake", "sapphirerapids", "emeraldrapids",
                "graniterapids", "cooperlake", "cannonlake", "x86-64-v4")

# upstream's list of the wide kernels that are wide on purpose. A mangled objdump name carries the plain one, so a
# substring is the test. When the file is not next to this one the list shrinks: the check then reports more, never less.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))         # tools/, where check_isa_guard.py lives
try:
    from check_isa_guard import WIDE_PUBLIC                          # the upstream-maintained list
except Exception as e:                                               # noqa: BLE001
    WIDE_PUBLIC = ("iq512", "iq_avx512", "nvfp4_512")
    print(f"check_hip_image: check_isa_guard.py's WIDE_PUBLIC not found ({e}): the short list only")
ANON = "_GLOBAL__N_1"                                                # internal linkage: only its own wide file reaches it
WIDE_NAME = re.compile(r"avx512|_512")

AVX512_LINE = re.compile(r"%zmm\b|%k[1-7]\b")
FUNC_HEAD = re.compile(r"^[0-9a-f]+ <(.+)>:$")


def wide_ok(name: str) -> bool:
    return ANON in name or any(k in name for k in WIDE_PUBLIC) or bool(WIDE_NAME.search(name))


def disassemble(binary: Path):
    """(avx2 lines, {function: AVX-512 lines}) of one binary, streamed out of objdump -d: a HIP engine binary is
    ~90 MB and strata-vision-hip ~200 MB, so no output list - a counter per function is enough memory-wise."""
    ymm, wide, current = 0, {}, "?"
    for line in subprocess.run(["objdump", "-d", "--no-show-raw-insn", str(binary)],
                               stdout=subprocess.PIPE, text=True, errors="replace", check=False).stdout.splitlines():
        head = FUNC_HEAD.match(line)
        if head:
            current = head.group(1)
            continue
        if AVX512_LINE.search(line):
            wide[current] = wide.get(current, 0) + 1
        elif "%ymm" in line:
            ymm += 1
    return ymm, wide


def check(binary: Path, march: str, problems: list) -> str:
    if not binary.is_file():
        problems.append(f"{binary.name} is missing")
        return f"{binary.name}: missing"
    if not (binary.stat().st_mode & 0o111):
        problems.append(f"{binary} is not executable (the manifest hashes content only)")
    ymm, wide = disassemble(binary)
    if not ymm:
        problems.append(f"{binary.name} holds no %ymm (AVX2) instruction: the CPU flags never reached the compile")
    wants_avx512 = march != "native" and any(m in march for m in AVX512_MARCH)
    if not wants_avx512:
        for name, n in sorted(wide.items(), key=lambda kv: -kv[1]):
            if not wide_ok(name):
                problems.append(f"{binary.name}: {n} AVX-512 lines in {name} - not a wide kernel behind a CPU check "
                                f"(check_isa_guard.py), and -march={march or 'native'} does not ask for AVX-512")
    allowed = sum(n for name, n in wide.items() if wide_ok(name))
    return (f"{binary.name} {binary.stat().st_size / 1e6:.0f} MB: {ymm} AVX2 lines, "
            f"{sum(wide.values())} AVX-512 lines in {len(wide)} functions"
            + (f" ({allowed} of them in wide kernels behind a CPU check)" if allowed else ""))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="an engine component package folder, or setup.py's engine/ folder")
    ap.add_argument("--march", default="", help="the CPU level the build asked for (tools/fork/build-hip.sh's CPU_MARCH)")
    ap.add_argument("--expect-vision", default="cpu", choices=("cpu", "gpu", "none"),
                    help="cpu: strata-vision must be there; gpu: strata-vision and strata-vision-hip; none: neither")
    a = ap.parse_args()
    if platform.system() != "Linux":
        print(f"check_hip_image: Linux only (here {platform.system()})")
        return 77
    if shutil.which("objdump") is None:
        print("check_hip_image: objdump not found (apt install binutils)")
        return 77
    eng, march, problems = Path(a.engine), a.march.strip().lower(), []
    stamp = eng / "BUILD.json"
    if not stamp.is_file():
        print(f"check_hip_image: {stamp} is missing: this is not an engine folder")
        return 1
    meta = json.loads(stamp.read_text(encoding="utf-8"))
    # two layouts: setup.py's engine/BUILD.json (backend, src) and an engine component (variant, portable,
    # vision_cpu / vision_gpu). Read the binaries from whichever of the two this is.
    if meta.get("variant") or meta.get("portable") is not None:
        readers = {"cpu": meta.get("vision_cpu") or "strata-vision", "gpu": meta.get("vision_gpu") or "strata-vision-hip"}
        kind = f"package variant {meta.get('variant')} portable={meta.get('portable')}"
        if meta.get("portable") is not True and march != "native":
            problems.append("BUILD.json: portable is not true on a build that names a CPU level")
    else:
        readers = {"cpu": "strata-vision", "gpu": "strata-vision-hip"}
        kind = f"local build backend={meta.get('backend')} src={str(meta.get('src'))[:8]} vision_src={str(meta.get('vision_src'))[:8]}"
        if meta.get("backend") != "hip":
            problems.append(f"BUILD.json: backend {meta.get('backend')}, expected hip")
        if not meta.get("src"):
            problems.append("BUILD.json: no src hash: the first start recompiles the engine")
    print(f"BUILD.json: {kind} version={meta.get('version')} archs={meta.get('archs')} vision={meta.get('vision')}")
    want = ["strata"] + ([readers["cpu"]] if a.expect_vision == "cpu" else
                         [readers["cpu"], readers["gpu"]] if a.expect_vision == "gpu" else [])
    for name in want:
        print("  " + check(eng / name, march, problems))
    for name in (readers["cpu"], readers["gpu"]):
        if name not in want and (eng / name).is_file():
            print("  " + check(eng / name, march, problems) + " (in the folder, not asked for)")
    for p in problems[:12]:
        print("PROBLEM: " + p, file=sys.stderr)
    if len(problems) > 12:
        print(f"PROBLEM: ... and {len(problems) - 12} more", file=sys.stderr)
    if problems:
        return 1
    print(f"check_hip_image: ok (-march={march or 'native'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
