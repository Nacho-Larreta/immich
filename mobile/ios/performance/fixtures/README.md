# T093 synthetic MP4 fixtures

This directory contains the reproducible generator for the non-personal videos
used by the TC-026 physical-device gate. Generated media is deliberately excluded
from the repository.

## Generate

Requirements: Python 3.11 or newer, `ffmpeg`, `ffprobe`, and at least 1.32 GiB of
free space.

```sh
python3 mobile/ios/performance/fixtures/generate_t093_fixtures.py
```

The default destination is `/private/tmp/immich-t093-fixtures`. The generator
refuses to write below a Git worktree, through a symlink, or into Git metadata and
never overwrites an existing fixture. The output directory is private (`0700`),
and generated files are `0600`. It creates:

- `fixture-256.mp4`: exactly 268435456 bytes;
- `fixture-1024.mp4`: exactly 1073741824 bytes;
- `manifest.json`: labels, exact sizes, allocated bytes, and SHA-256 digests.

One private, randomly named staging directory is opened once and retained by file
descriptor for the full run. Generation, hashing, allocation checks, and `ffprobe`
all operate on the same staged file descriptors. Final files are published with
atomic, no-overwrite hard links; `manifest.json` is published last as the completion
marker. If publication is interrupted, a fixture may remain without a manifest;
the generator will refuse to overwrite it on the next run.

Each file starts with the same synthetic video-only MP4 and ends with one standard
ISO-BMFF `free` box. Its deterministic pseudo-random payload is streamed through
ordinary writes, followed by `fsync`; neither sparse-file creation nor `truncate`
is used. Generation fails if `ffprobe` rejects a result, an audio stream exists,
the logical size is wrong, or `st_blocks * 512` is smaller than the logical size.

APFS can report shared or filesystem-managed physical extents through `st_blocks`.
The allocation gate detects holes and transparent compression, while sequential
non-compressible writes plus `fsync` ensure every logical byte is materialized; it
does not prove that an extent is uniquely owned by this inode.

Hashes are reproducible across repeated runs with the observed Python and FFmpeg
toolchain. Those versions are not pinned here, so identical hashes across different
toolchain versions are not guaranteed. The exact size, ISO-BMFF structure,
allocation, and probe checks remain mandatory regardless of the resulting hash.

## Test

```sh
PYTHONPYCACHEPREFIX=/private/tmp/immich-t093-pycache \
  python3 -m unittest discover -s mobile/ios/performance/fixtures -p 'test_*.py'
```

The suite uses only small files. It includes a focal `ffmpeg`/`ffprobe` integration
test and never creates the 256 MiB or 1 GiB fixtures.
