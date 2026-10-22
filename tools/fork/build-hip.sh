#!/bin/sh
# The fork's AMD (HIP) image, built from two upstream steps with one pin added:
#
#   packaging/build_hip_linux.sh   the engine, the CPU picture reader and the GPU picture reader, the ROCm
#                                  libraries they load, the rocBLAS / hipBLASLt kernel data and the tuning tables,
#                                  packaged as an engine component (upstream's own release recipe)
#   docker/build.sh --flavor hip   that package inside upstream's runtime image (Terminal + entrypoint)
#
# The one thing this script adds is the CPU instruction set: CFLAGS / CXXFLAGS are exported for cmake's first
# configure, so the CPU kernels of all three binaries are compiled for one x86-64 level instead of the build
# host's. Upstream builds them portable (STRATA_PORTABLE=ON: the AVX2 baseline), which is already safe on every
# AVX2 CPU; -march=<level> tunes them for the CPU of the PC the image is meant for and keeps a wide build
# machine (a CI runner with AVX-512) from leaking wide code into an image for a narrow PC. tools/fork/
# check_hip_image.py is the guard that says so.
#
# Everything is an environment variable:
#
#   tools/fork/build-hip.sh                                    # gfx1101 (RX 7800 XT) at znver1
#   ARCHS=gfx1100;gfx1102 CPU_MARCH=znver3 tools/fork/build-hip.sh
#   CPU_MARCH=native tools/fork/build-hip.sh                   # this build host's own level, as upstream
#   SKIP_IMAGE=1 tools/fork/build-hip.sh                       # the engine package only
#   HP=/path/to/rocm tools/fork/build-hip.sh                   # a ROCm that is already installed
#   EXPECT_VISION=gpu|cpu|none tools/fork/build-hip.sh         # which picture readers the guard must find (gpu: both)
#   BIN=podman tools/fork/build-hip.sh                         # the container tool for the image (docker by default)
#
# The machine needs: git curl python3 (+ venv), build-essential, cmake, ninja, patchelf, binutils (objdump,
# readelf), and docker or podman for the image (podman: BIN=podman). ROCm comes from AMD's TheRock
# index for the arch - setup.py's own version choice - into .venv-rocm, unless HP= names one.
#
# Start the image (the card's render node and /dev/kfd, nothing published beyond 127.0.0.1):
#
#   docker run -d --name strata --device /dev/kfd --device /dev/dri \
#     --group-add video --group-add $(getent group render | cut -d: -f3) \
#     -p 127.0.0.1:8080:8080 --ulimit memlock=-1:-1 --shm-size 2g --stop-timeout 120 \
#     -v strata-data:/data -e MODEL=IQ3_XXS -e API_KEY=$(openssl rand -hex 24) -e VISION=cpu \
#     <the tag this script printed>
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
ARCHS=${ARCHS:-gfx1101}                       # gfx1101: RX 7800 XT / 7700 XT; gfx1100: RX 7900 XT / XTX
CPU_MARCH=${CPU_MARCH:-znver1}                # znver1 = AMD Zen 1 (Threadripper 1950X, Ryzen 1000)
VARIANT=${VARIANT:-$(printf '%s-%s' "${ARCHS%%;*}" "$CPU_MARCH" | tr 'A-Z' 'a-z')}
OUT=${OUT:-${TMPDIR:-/tmp}/strata-hip-$VARIANT}     # outside the checkout: the three build trees and the package
JOBS=${JOBS:-$(nproc)}
BIN=${BIN:-docker}                            # podman: BIN=podman
TAG=${TAG:-strata-hip:$VARIANT}
EXPECT_VISION=${EXPECT_VISION:-gpu}           # upstream's recipe builds both readers, so the guard asks for both
venv=${venv:-${TMPDIR:-/tmp}/strata-hip-venv}  # the ROCm wheels are ~10 GB, so not inside the checkout
first=$(printf '%s' "${ARCHS%%;*}" | tr ',' '\n' | head -1)

say() { printf '%s\n' "$*"; }

case "$EXPECT_VISION" in                              # gpu: both picture readers must be in the image
  gpu|cpu|none) ;; *) say "EXPECT_VISION=$EXPECT_VISION is not gpu, cpu or none" >&2; exit 2 ;;
esac

# build_hip_linux.sh writes what it does into files under OUT (its build.status is the step list, each cmake step
# has its own log), and the image build makes a temporary context folder. On a CI runner those files are the only
# way to see why a step failed, so they are printed when this script stops with an error, and the folder is left
# behind. A trap covers the whole script, so one EXIT handler does both.
shim=""
dump() {
  if [ -f "$OUT/build.status" ]; then echo "== $OUT/build.status"; sed 's/^/  /' "$OUT/build.status"; fi
  for f in cfg cfg-vision cfg-vision-hip build build-vision build-vision-hip collect stage_tuning package; do
    if [ -f "$OUT/$f.log" ]; then
      echo "== $OUT/$f.log (last 40 lines)"
      tail -40 "$OUT/$f.log" | sed 's/^/  /'
    fi
  done
}
on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "build-hip.sh: stopped with exit $rc; the build logs:"; dump; fi
  if [ -n "$shim" ]; then rm -rf "$shim"; fi
}
trap on_exit EXIT

# ---- 1. the Python environment setup.py needs (cmake and ninja come from it, as setup.py installs them)
if [ ! -x "$venv/bin/python" ]; then
  say "venv: $venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q --upgrade pip
  "$venv/bin/pip" install -q -r "$repo/requirements.txt" -r "$repo/requirements-build.txt"
fi
py="$venv/bin/python"
cd "$repo" || exit 1

# ---- 2. ROCm for the arch's family (setup.py's own index and version choice), then llama.cpp at the pinned commit
if [ -z "${HP:-}" ]; then
  idx=$("$py" -c "import setup; print(setup.rocm_index('$first'))")
  ver=$("$py" -c "import setup; print(setup.rocm_wanted('$idx')[0])")
  say "ROCm: rocm[libraries,devel]==$ver from $idx"
  "$py" -m pip install -q --disable-pip-version-check --index-url "$idx" "rocm[libraries,devel]==$ver"
  HP=$("$venv/bin/rocm-sdk" path --root)
  say "ROCm root: $HP"
fi
# llama.cpp at the pinned commit. Its fetch prints progress on stdout ("llama.cpp source: 0.01 / 0.04 GB"), so
# the path is read from the last line only - a captured multi-line value ends up in -DSTRATA_GGML_DIR and the
# engine configure fails on a machine that has to download it (the CI's case; a warm checkout hides it).
llama=${LLAMA:-$("$py" -c "import setup; print(setup.get_llama_cpp())" | tail -1)}
if [ ! -d "$llama" ]; then say "no llama.cpp checkout at '$llama' (setup.get_llama_cpp failed)" >&2; exit 1; fi
say "llama.cpp: $llama"

# ---- 3. the CPU level for every binary's CPU kernels: cmake takes CFLAGS / CXXFLAGS on a folder's first
# configure, and packaging/build_hip_linux.sh always configures fresh folders. The portable definition stays
# as upstream sets it, so the only added instruction set is the one named here.
if [ "$CPU_MARCH" != native ]; then
  CFLAGS="-march=$CPU_MARCH" CXXFLAGS="-march=$CPU_MARCH"
  export CFLAGS CXXFLAGS
  say "CPU level: -march=$CPU_MARCH (upstream builds the AVX2 baseline; this tunes it and pins the ceiling)"
else
  say "CPU level: native (this build host), as a plain source build"
fi

pkgver=${PKGVER:-$(sed -n 's/^[[:space:]]*project([^)]*VERSION[[:space:]]*\([0-9][0-9.]*\).*/\1/p' CMakeLists.txt | head -1)}
commit=${COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}
say "package: variant $VARIANT, archs $ARCHS, version $pkgver, commit $commit, $JOBS jobs"

# ---- 4. upstream's release recipe, unchanged. cmake, ninja and the python3 its packaging scripts run all come
# from the venv (setup.find_tool's own rule: the ones next to this Python), so its bin/ goes first on PATH.
export PATH="$venv/bin:$PATH"
core=${CORE:-$HP}
libw=${LIBW:-$HP}
export VARIANT="$VARIANT" ARCHS="$ARCHS" SRC="$repo" LLAMA="$llama" HP="$HP" CORE="$core" \
  LIBW="$libw" OUT="$OUT" PKGVER="$pkgver" COMMIT="$commit" JOBS="$JOBS"
if [ -n "${VISION_ONLY:-}" ]; then export VISION_ONLY; fi
if [ -n "${NO_PACKAGE:-}" ]; then export NO_PACKAGE; fi

bash packaging/build_hip_linux.sh   # upstream script: bash (arrays, ${var//x/y})
pkg=$(find "$OUT/components/engine" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$pkg" ] || { say "no package under $OUT/components/engine (see $OUT/package.log)" >&2; exit 1; }

# ---- 5. the guard: the binaries are there, and they hold the CPU level asked for and no wider one
"$py" tools/fork/check_hip_image.py --engine "$pkg" --march "$CPU_MARCH" --expect-vision "$EXPECT_VISION"

if [ -n "${SKIP_IMAGE:-}" ]; then say "package: $pkg (SKIP_IMAGE: no image built)"; exit 0; fi

# ---- 6. upstream's image build. docker/build.sh calls `docker` by name, so a tool with another name (podman)
# needs a shim named docker first on PATH. The shim execs the resolved path, never the bare name: a shim that
# execs `docker` finds itself, and an exec loop prints nothing at all - with BIN=docker (CI's setting) that is
# what filled the runner's 300 minutes in the run before this fix (measured on this PC: 1847 execs in 5 s).
# So: no shim when the tool already is docker, and an absolute path in the shim when it is not.
if [ "$BIN" = docker ]; then
  say "container tool: docker"
else
  case $BIN in
    /*) real=$BIN ;;
    *)  real=$(command -v "$BIN" 2>/dev/null || true) ;;
  esac
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    say "no container tool '$BIN' (give its path in BIN, or BIN=docker)" >&2; exit 1
  fi
  say "container tool: $real, behind a shim named docker for docker/build.sh"
  shim=$(mktemp -d)
  { printf '#!/bin/sh\nexec "%s" "$@"\n' "$real"; } > "$shim/docker"
  chmod +x "$shim/docker"
  PATH="$shim:$PATH"
fi
docker/build.sh --flavor hip --engine "$pkg" --tag "$TAG" --version "$pkgver"   # the shim, or the real docker

# ---- 7. the same binaries, read out of the built image, and what the image makes of this computer's card.
# A CI runner has no AMD card, so `strata components engine` there says so: that is the honest answer, and
# the step that proves the image on a real card is the run at the top of this file.
cid=$($BIN create "$TAG" true 2>/dev/null | tail -1)
out="$OUT/image-engine"; rm -rf "$out"; mkdir -p "$out"
$BIN cp "$cid:/opt/strata/components/engine/." "$out" >/dev/null
$BIN rm "$cid" >/dev/null
"$py" tools/fork/check_hip_image.py --engine "$out"/* --march "$CPU_MARCH" --expect-vision "$EXPECT_VISION"
$BIN run --rm --entrypoint /opt/strata/terminal/bin/strata "$TAG" components engine 2>&1 | sed 's/^/  /' || true

say ""
say "image:   $TAG  ($($BIN image inspect "$TAG" --format '{{.Size}}') bytes)"
say "package: $pkg"
say "pictures: start the container with -e VISION=cpu (the CPU reader) or -e VISION=gpu (the GPU reader, from"
say "24 GB of VRAM: strata_control/vision_reader.py's own default for this card)"
