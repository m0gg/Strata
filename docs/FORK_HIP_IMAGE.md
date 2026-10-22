# Fork: the AMD (HIP) container for an RX 7800 XT (gfx1101) on a Zen 1 PC

A fork's own document, for one feature branch. It is the only document the branch touches:
[DOCKER.md](DOCKER.md), [AMD_HIP.md](AMD_HIP.md), [INSTALL.md](INSTALL.md) and [DETAILS.md](DETAILS.md) stay
exactly as upstream has them, so rebasing onto upstream never conflicts in a document.

Feature branch `feature/hip-gfx1101-image`, four fork-owned files and nothing else:

| File | What it is |
| --- | --- |
| `tools/fork/build-hip.sh` | runs upstream's `packaging/build_hip_linux.sh` and `docker/build.sh --flavor hip` with `-march=<level>` exported for cmake's first configure; `BIN=` names the container tool |
| `tools/fork/check_hip_image.py` | the guard: the picture readers asked for are there, executable, and their machine code is the x86-64 level asked for and no wider (`--expect-vision gpu|cpu|none`) |
| `.github/workflows/hip-image.yml` | builds that image on pushes to the branch, runs the guard on the package and on the image's own copy, and publishes to `ghcr.io/<you>/strata-hip` |
| `docs/FORK_HIP_IMAGE.md` | this document |

Nothing in `src/`, `include/`, `packaging/`, `docker/`, `strata_control/`, `serve/`, `setup.py` or
`CMakeLists.txt` changes: the branch is a wrapper around upstream's own recipes, so the engine's default path
is byte-identical to upstream and a rebase touches only fork-owned paths.

## What upstream already ships for this PC

Since 0.2.1 upstream publishes ready-made images built from its engine component packages
([DOCKER.md](DOCKER.md)), and one of them is this card family: `ghcr.io/niko1221/strata:<version>-rocm-gfx110x`
for the RX 7000 series (gfx1100 / gfx1101 / gfx1102). 2.4 GB on disk, about a third of that to download
(upstream's numbers, measured on the 0.1.45 packages). One command, nothing compiled on your side:

```sh
docker run -d --name strata --device /dev/kfd --device /dev/dri \
  --group-add video --group-add $(getent group render | cut -d: -f3) \
  -p 127.0.0.1:8080:8080 --ulimit memlock=-1:-1 --shm-size 2g --stop-timeout 120 \
  -v strata-data:/data -e MODEL=IQ3_XXS -e API_KEY=$(openssl rand -hex 24) \
  ghcr.io/niko1221/strata:0.2.2-rocm-gfx110x
```

Measured here on the released package for that family (`strata-engine-0.1.47-linux-x86_64-hip-rx7900.tar.gz`,
242 MB, the v0.2.2 asset): `archs = gfx1100, gfx1101, gfx1102`, `portable: true`, and three binaries -

| binary | size | AVX2 lines | AVX-512 lines |
| --- | --- | --- | --- |
| `strata` | 93 MB | 50 771 | 1 150, in 62 functions, all of them upstream's wide kernels behind a CPU check |
| `strata-vision` (CPU picture reader) | 8 MB | 17 324 | 0 |
| `strata-vision-hip` (GPU picture reader) | 207 MB | 17 269 | 0 |

Plus the rocBLAS / hipBLASLt kernel data for gfx1100 and gfx1101 and the ROCm runtime it needs, bundled and
pointing at `$ORIGIN`. So the CPU code of upstream's AMD package is the AVX2 baseline: it runs on this PC's
AMD Zen 1 (Threadripper 1950X), and pictures are on by default with the CPU reader (the GPU reader is the
default from 24 GB of VRAM, and this card has 16 GB; `strata_control/vision_reader.py`).

**Use that image, and the fork is not needed**, if the only question is "does Strata run in a container on this
PC". The fork is for the two things upstream's path does not cover: the CPU code *tuned* for one x86-64 level
rather than the shared baseline, and an image whose build machine may be wider than the PC it runs on.

## What the fork adds

`tools/fork/build-hip.sh` runs upstream's release recipe with `CFLAGS`/`CXXFLAGS=-march=$CPU_MARCH` exported
(znver1 = AMD Zen 1 by default, the CPU of this fork's PC). cmake picks them up on a build folder's first
configure, and `packaging/build_hip_linux.sh` always configures fresh folders, so the flag reaches the CPU
kernels of all three binaries - the engine, the CPU picture reader and the GPU picture reader - while upstream's
`STRATA_PORTABLE=ON` stays as it is. Two effects:

- the code is scheduled for the CPU the image is for, not for the lowest shared baseline;
- the ceiling is pinned: a build on a wide machine (the CI's AVX-512 Xeon) cannot put AVX-512 into an image
  tagged for a Zen 1 PC. `tools/fork/check_hip_image.py` reads the binaries and stops the build when it does -
  in the package, and again in the copy pulled out of the finished image.

The speed difference between the AVX2 baseline and `-march=znver1` on a model has **not been measured**: it needs
a 68-84 GB model on the card, which is the person's step, not the CI's. What is measured is the ISA
(the table above and the CI's own run), so the honest claim is: an image tuned and pinned for this CPU, published
by CI, with a guard that says which instruction set is inside.

## Build the fork's image

Everything is an environment variable; the defaults are this PC's card and CPU:

```sh
tools/fork/build-hip.sh                                   # gfx1101 at -march=znver1, image strata-hip:gfx1101-znver1
ARCHS=gfx1100;gfx1102 CPU_MARCH=znver3 tools/fork/build-hip.sh
CPU_MARCH=native tools/fork/build-hip.sh                   # the build host's own level, as a plain source build
SKIP_IMAGE=1 tools/fork/build-hip.sh                       # the engine package only
EXPECT_VISION=cpu tools/fork/build-hip.sh                  # the guard asks for the CPU reader only
BIN=podman tools/fork/build-hip.sh                         # podman instead of docker
```

`BIN=` is the container tool. `docker/build.sh` calls `docker` by name, so for podman the script puts a shim named
`docker` first on `PATH`, and that shim execs the resolved path. It never execs a bare name: a shim that execs
`docker` finds itself, and the loop prints nothing - the run before this fix spent 4 h 40 min in it ("The CI").

It installs the TheRock ROCm wheels setup.py would pick for the arch (into `/tmp/strata-hip-venv`), fetches
llama.cpp at the pinned commit, calls upstream's two scripts, and runs the guard twice. What the machine needs:
`git curl python3 python3-venv build-essential cmake ninja patchelf binutils`, plus docker (or podman) for the
image. Building in a plain Ubuntu container, with this checkout at `/src`:

```sh
podman run --rm -v "$PWD":/src -w /src -v /tmp/strata-hip-work:/work \
  -e OUT=/work -e venv=/work/venv -e SKIP_IMAGE=1 ubuntu:24.04 \
  bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential binutils \
             patchelf curl git python3 python3-venv ca-certificates >/dev/null && sh tools/fork/build-hip.sh'
```

The guard, on a package folder, on setup.py's `engine/` folder, or on an image's copy:

```sh
python3 tools/fork/check_hip_image.py --engine <folder> --march znver1 --expect-vision gpu
```

The CI pushes the image to `ghcr.io/<you>/strata-hip`. A package that a workflow pushes with its own token takes
the repository's visibility, and this fork is public, so the pull needs no login - measured on 23 Oct: the image
of run 4 pulled on this PC with an empty auth file (podman: `--authfile` a file holding `{}`; plain `docker pull`
asks no question at all), 1.2 GB, and it runs on the card:

```sh
docker pull ghcr.io/<you>/strata-hip:gfx1101-znver1     # every build also keeps the tag gfx1101-znver1-<sha>
```

If the package is private, the pull needs a login first:

```sh
gh auth token | docker login ghcr.io -u <you> --password-stdin
```

Start the image (the card's node and `/dev/kfd`; the server needs a key, 16 characters or more):

```sh
docker run -d --name strata --device /dev/kfd --device /dev/dri \
  --group-add video --group-add $(getent group render | cut -d: -f3) \
  -p 127.0.0.1:8080:8080 --ulimit memlock=-1:-1 --shm-size 2g --stop-timeout 120 \
  -v strata-data:/data -e MODEL=IQ3_XXS -e API_KEY=$(openssl rand -hex 24) \
  strata-hip:gfx1101-znver1
curl -s localhost:8080/health
```

## The CI

`.github/workflows/hip-image.yml` runs on pushes to the branch (and on the paths that change what goes into the
image), on pull requests, and by hand with every knob as an input: gfx targets, `-march`, which picture readers
must be there, push on/off. One job: system packages (patchelf, binutils), free disk (~10 GB of wheels, three
build trees and the image), `tools/fork/build-hip.sh`, and a push of `<arch>-<march>` and `<arch>-<march>-<sha>`
only when the guard passed.

What it cannot do is run a card: a hosted runner has no GPU, so the image's own `strata components engine` reports
no card there. Starting a model is "Start the image" above, and a report from a real card is what
[COMMUNITY_BENCHMARKS.md](COMMUNITY_BENCHMARKS.md) asks for.

The hosted job, measured on this fork (m0gg/Strata, `ubuntu-latest`, 4 cores / 16 GB):

| run | what it built | result |
| --- | --- | --- |
| #1, 22 Oct 18:36 | the earlier shape: a source-build Dockerfile, no package recipe | success, 17 min 6 s, image 12.2 GB, push 40 s, and its binaries matched this PC's (`src=b9513716`, `strata-vision` 15 637 AVX2 lines, 0 AVX-512) |
| #2, 22 Oct 20:16 | this shape | failed after 6 min: the llama.cpp folder was read out of a multi-line capture, so cmake's `-DSTRATA_GGML_DIR` got the download's progress text; `tail -1` fixes it, and a checkout that already has llama.cpp hides it |
| #3, 22 Oct 20:35 | this shape, llama.cpp fixed | hung 4 h 40 min in the image build; cancelled by the job's 300 min limit |
| #4, 23 Oct 09:21 | this shape, with the fixes below | **success, 28 min 15 s** (09:21:23 → 09:49:38): venv, ~10 GB of wheels and llama.cpp 1 min 55 s, engine package 21 min 14 s (`JOBS=8` on 4 cores), image 1 min 52 s and 1 193 808 077 bytes, guard on the package and on the image's copy ok, pushed `ghcr.io/m0gg/strata-hip:gfx1101-znver1` and `…:gfx1101-znver1-59657af9ff01` in 25 s |

Run #3 is the one to read, because everything up to the image was right:

- the venv and the ~10 GB of ROCm wheels: 7 min 38 s (20:35:36 → 20:43:14);
- the engine package: 11 min 46 s (20:43:14 → 20:55:00), ending in guard lines **identical to this PC's** -
  `strata 39 MB: 57 543 AVX2 lines, 1 249 AVX-512 lines in 58 functions`, `strata-vision 8 MB: 15 697 AVX2 lines,
  0 AVX-512`, `strata-vision-hip 85 MB: 15 640 AVX2 lines, 0 AVX-512`. The AVX-512 that runner's Xeon could have
  emitted sits only in the wide kernels behind a CPU check, which is what the guard is for;
- the image build: one line at 20:55:00 and nothing for 4 h 40 min, then the cancel.

The cause is in the fork's own script and shows only on a machine that has docker: the shim named `docker`, made
for podman, execs `docker`, finds itself first on `PATH` and execs again. Measured on this PC with that shim:
1 847 execs in 5 s, no output, no error - the loop cannot print, so the runner's log was silent and the only way
to see it was the orphan process list at the cancel (`build-hip.sh`, `build.sh`, `docker`). Now: no shim when the
tool already is docker, and a shim that execs a resolved path when it is not.

Two more things came out of that run: the job's `timeout-minutes` is 90 instead of 300 (run 4 measures the whole
job at 28 min 15 s, so a stall now ends in 90 min and not in 5 h), the build step has its own
60 min limit, and its log is kept in `$RUNNER_TEMP` so a Summary step prints the guard's lines, the image size and
the tags on the run page - `if: always()`, because that is when they are wanted.

Two knobs of the same job were dead, and are now wired: `-march` reaches the build as `CPU_MARCH`, written from
`MARCH` in the Defaults step (the version before set only `MARCH`, so a manual `cpu_march=znver3` built at the
script's own default znver1 and published it under a `znver3` tag), and `expect_vision` reaches the guard as
`EXPECT_VISION` (it set the variable and nothing read it, so the guard always checked the CPU reader and reported
the GPU reader as "in the folder, not asked for").

Measured on this PC (RX 7800 XT / Threadripper 1950X / 126 GB, podman 5.8.8, 32 threads, `JOBS=16`,
`ARCHS=gfx1101`, `CPU_MARCH=znver1`):

| | |
| --- | --- |
| `tools/fork/build-hip.sh` (engine 2 min, CPU reader 29 s, GPU reader 2 min 23 s, collect + package 1 min) | 311 s, with the ROCm wheels already installed |
| `tools/fork/build-hip.sh` from nothing, in a plain `ubuntu:24.04` container (`apt`, the venv, the ~10 GB of ROCm wheels, the whole package, `JOBS=16`) | 8 min 55 s (23 Oct, 07:34:07 → 07:43:02); the guard then asks for both readers (`--expect-vision gpu`) and its lines are the same as the 22 Oct build's |
| engine package | 740 MB, 292 files, `variant=gfx1101-znver1 archs=['gfx1101'] portable=True build_id=07cbf9a1+rocm` |
| `docker/build.sh --flavor hip` (the Terminal's pinned Python + locked wheels dominate) | 353 s |
| image | 1.20 GB on disk (1 202 517 290 bytes) |
| `strata` | 39 MB: 57 543 AVX2 lines, 1 249 AVX-512 lines in 58 functions, all 58 the wide kernels behind a CPU check |
| `strata-vision` | 8 MB: 15 697 AVX2 lines, 0 AVX-512 lines |
| `strata-vision-hip` | 85 MB: 15 640 AVX2 lines, 0 AVX-512 lines |
| in the container, with the card: `strata components engine --output json` | `"usable": true`, `archs=["gfx1101"]`, `backend=hip`, `build_id=07cbf9a1+rocm`, 292 files, 774 961 821 bytes, `"problems": []` |
| in the container: `strata --version`, `strata --families` | `strata 0.1.47`, `qwen4exp qwen35moe` |
| in the container with the card: `strata launch --plan --model q2_0 --output json` | `"ok": true`, `"engine_missing": false`, "About 72.5 GB to download: the model (66.4 GB), the draft layer (5.2 GB) and the picture reader (0.9 GB)" - the engine is found on the card and the picture path is planned, nothing downloaded |
| the guard on the copy pulled out of the built image (`--expect-vision gpu`) | `check_hip_image: ok (-march=znver1)`, 12.5 s |
| the image published by CI run 4, pulled on this PC and read: guard, then `strata components engine` on the card | guard ok, the same three ISA lines as the runner printed them, `build_id=59657af+rocm`, `archs=["gfx1101"]`, `"usable": true`, `"problems": []`, 292 files, 775 012 836 bytes - the published image runs on the PC it is tagged for |
| the same, on a second build of 23 Oct from the container's package: image, guard on the image's copy, `strata components engine` on the card | image 1 202 517 292 bytes (22 Oct: 1 202 517 290), guard ok, `build_id=336cd59e+rocm`, `"usable": true` |
| podman as the container tool | `podman build` drops the image's `HEALTHCHECK` (its own warning: "HEALTHCHECK is not supported for OCI image format"), so `docker/healthcheck.sh` runs only in a `docker build` image - the CI's case. Everything above in this row ran on the podman image. |

The one arch matters for size: upstream's package carries code for gfx1100, gfx1101 and gfx1102 and its
`strata` is 93 MB, `strata-vision-hip` 207 MB; the fork's gfx1101-only build is 39 MB and 85 MB.

The guard's failure path, measured the same way: the same build at `CPU_MARCH=x86-64-v4` (322 s) passes its
own check, and fails when read as a Zen 1 image -

```
strata 40 MB: 64 566 AVX2 lines, 3 662 AVX-512 lines in 137 functions (1 496 in wide kernels)
strata-vision 8 MB: 36 073 AVX2 lines, 2 883 AVX-512 lines in 79 functions
PROBLEM: strata: 360 AVX-512 lines in quantize_row_mxfp4_ref - not a wide kernel behind a CPU check
PROBLEM: strata: 127 AVX-512 lines in ggml_compute_forward_im2col - ...
PROBLEM: strata: 126 AVX-512 lines in strata::core::expert_pool_dispatch_multi - ...
exit 1
```

One gap this build shows: `packaging/stage_tuning.py` reports `no hipBLASLt table for gfx1101 with hipBLASLt
100200 (the repo has: none): plain hipBLAS there` - `tools/hip/` has tables for gfx1100, gfx1103, gfx1150,
gfx1151 and gfx1201, none for gfx1101. [TEST_REQUESTS.md](TEST_REQUESTS.md) asks for RX 7000 reports ("the
Docker image for them is also untested on a card"), so a start on this PC is worth reporting upstream, and a
tuned gfx1101 table is the thing to bring from it.

## Updating the fork from upstream

The branch is rebased, never merged: it holds no change of its own in the engine, so a rebase replays one commit
onto upstream's `main`.

```sh
git fetch upstream --tags
git switch feature/hip-gfx1101-image
git rebase upstream/main
git push --force-with-lease origin feature/hip-gfx1101-image
git branch -f main upstream/main && git push origin main      # the fork's main follows upstream
```

Only three paths are the fork's - `tools/fork/` (the two scripts), `.github/workflows/hip-image.yml` and
`docs/FORK_HIP_IMAGE.md` - so anything outside them in a diff of the branch is a mistake. Check it after a rebase
with `git diff --stat upstream/main...HEAD`: it must list those three paths and nothing else.

The fork's `main` mirrors upstream, so set it as the repository's default branch and leave the feature branch as a
branch (GitHub made this branch the default when it was pushed first, which makes the fork look like it owns
changes it does not):

```sh
gh repo edit <you>/Strata --default-branch main
```

A force-push to this branch is a normal event: it is what a rebase produces. The branch's commits are unsigned on
purpose (the GPG key needs a PIN at every commit); upstream's releases do not depend on them.

Conflicts: only if upstream takes the fork's own paths. Look before rebasing, and drop the fork's copy of anything
upstream now has:

```sh
git log --oneline <last-rebased-commit>..upstream/main -- tools/fork .github/workflows/hip-image.yml docs/FORK_HIP_IMAGE.md
```

The fork calls upstream code in five places; after a rebase, re-check these (the first three are what the build
depends on, the last two what the guard reads):

| Upstream | What the fork leans on |
| --- | --- |
| `packaging/build_hip_linux.sh` | its environment contract (`VARIANT ARCHS SRC LLAMA HP CORE LIBW OUT PKGVER COMMIT JOBS`), that it configures fresh cmake folders (so `CFLAGS`/`CXXFLAGS` reach the configure), and `STRATA_PORTABLE=ON` in the three configure lines |
| `docker/build.sh` | that it calls `docker` by name (so for podman the fork puts a shim named `docker` first on PATH, execing a resolved path: a shim that execs the bare name finds itself - see "The CI") and that it takes the package folder as `--engine` |
| `setup.py` | `rocm_index()`, `rocm_wanted()`, `get_llama_cpp()`, `AMD_ARCHS`, and the `cmake`/`ninja` from `requirements-build.txt` next to the venv's Python (`setup.find_tool`) |
| `packaging/package_engine.py` | the package layout: `BUILD.json` with `variant`, `portable`, `vision_cpu`, `vision_gpu`, and the folder name `<version>-linux-x86_64-hip-<variant>` |
| `tools/check_isa_guard.py` | `WIDE_PUBLIC`, the list of kernels that may be wide because their callers test the CPU first (the fork's guard imports it, and falls back to a short list with a printed note if the import fails) |

Then the checks, in this order. The first three need no card and no model - run them in a plain Ubuntu 24.04
container with this checkout at `/src` and the fork's venv mounted (the venv's `python3` is the container's
`/usr/bin/python3`, and `test_vision_reader.py` needs the project's `requirements.txt` on the path):

```sh
PYTHONPATH=/src /work/venv/bin/python tools/test_setup_amd.py            # setup's own tests
PYTHONPATH=/src /work/venv/bin/python tools/test_setup_choices.py
PYTHONPATH=/src /work/venv/bin/python tools/test_vision_reader.py        # the picture-reader choice
tools/fork/build-hip.sh                                                  # the build, which runs the guard itself
python3 tools/fork/check_hip_image.py --engine <the package folder> --march znver1 --expect-vision gpu
```

Then the hosted build, which is the copy that gets published (the job runs on pushes to the branch, and by hand
with every knob):

```sh
gh workflow run hip-image.yml --repo <you>/Strata --ref feature/hip-gfx1101-image
gh run list --repo <you>/Strata --workflow hip-image.yml --limit 3      # the Summary of a run carries the guard's lines
```

Then on the card, which is the rebase's real test: start the image and read `/health`, then the model
(`strata components engine` says whether the image's gfx target fits the card), and the picture path (the CPU
reader on a 16 GB card).

A rule that keeps the rebase cheap: the branch does not edit upstream files. If something belongs upstream (a
`--march` knob in `build_hip_linux.sh`, a gfx1101 example in [DOCKER.md](DOCKER.md)), it is a pull request there,
and the fork carries its own copy until upstream takes it - then the fork's copy goes away at the next rebase.
Upstream's own AMD packages are already AVX2-portable, so the case for a march knob is a measured speed gain:
bring the numbers (see [COMMUNITY_BENCHMARKS.md](COMMUNITY_BENCHMARKS.md)).

## What this branch does not do

- No GPU picture reader of its own: upstream's package carries `strata-vision-hip`, and
  `strata_control/vision_reader.py` picks the CPU reader below 24 GB of VRAM (this card: 16 GB) with the GPU one
  as its fall-forward choice.
- No CUDA, SYCL, Metal or Windows path, and no engine package of upstream's release feed: the fork builds from
  source for one gfx target and one x86-64 level.
- Nothing published beyond `127.0.0.1`, and the server runs only with an API key (the entry point makes one when
  none is given).
