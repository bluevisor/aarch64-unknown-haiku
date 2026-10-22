#!/bin/bash
# Build a Haiku-hosted Rust toolchain (rustc + rust-std) for aarch64-unknown-haiku,
# cross-compiled from aarch64 Linux with Rust's own bootstrap.
#
# Needs the Haiku arm64 cross toolchain and sysroot from
# https://github.com/bluevisor/haiku-arm64-bootstrap (build-bfs-shell.sh,
# build-cross-tools.sh incl. gcc_syslibs; build-tls.sh for cargo's libcurl).
# This repo is mounted at /repo. Output:
# /repo/out/rust/{rustc,rust-std}-nightly-aarch64-unknown-haiku.tar.gz
#
# Phases (~35 min on 12 cores, ~28 GB RAM recommended):
#   std   x.py build library  -- LLVM for Linux, stage1 rustc, std for Haiku (~16 min)
#   dist  x.py dist rustc rust-std -- LLVM cross-built for Haiku, Haiku-hosted rustc (~17 min)
#
# Prior art: felipedbene/Haiku-Graviton (graviton/scripts/haiku-rust-bake) and
# rainygirl/renkuos-rchromium-arm64 (rust/) did the same; this follows their
# approach. aarch64-unknown-haiku is not an upstream target.
set -euxo pipefail

RUST_COMMIT=${RUST_COMMIT:-1a2c4797ef2570bd76ca5dee34449169bc7dc457}   # nightly 2026-10-22, 1.101.0
T=aarch64-unknown-haiku
X=/build/haiku/generated.arm64/cross-tools-arm64
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
BIN=/build/rust-bin
OUT=/repo/out/rust

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake ninja-build curl git python3 g++ pkg-config >/dev/null 2>&1

mkdir -p /build/rust && cd /build/rust
[ -d .git ] || { git init -q . && git remote add origin https://github.com/rust-lang/rust.git; }
if [ "$(git rev-parse HEAD 2>/dev/null)" != "$RUST_COMMIT" ]; then
	git fetch -q --depth 1 origin "$RUST_COMMIT" && git checkout -q FETCH_HEAD
fi
# File::lock must be wired to flock() on Haiku (rust-lang/rust#164031, nightly >= 2026-10-13);
# otherwise it returns Unsupported and cargo silently skips its locking.
[ "$(grep -c 'target_os = "haiku"' library/std/src/sys/fs/unix.rs)" -ge 10 ]

# The target: patches/rust-aarch64-unknown-haiku.patch (spec + registration).
if ! grep -q aarch64_unknown_haiku compiler/rustc_target/src/spec/mod.rs; then
	git apply /repo/patches/rust-aarch64-unknown-haiku.patch
fi

# Cross compiler wrappers. Haiku keeps BSD/socket/glibc-compat functions in
# libbsd/libnetwork/libgnu; they must follow rustc's own object list.
mkdir -p $BIN
for t in gcc g++; do
	cat > $BIN/haiku-rust-$t <<EOF
#!/bin/sh
exec $X/bin/aarch64-unknown-haiku-$t -D_DEFAULT_SOURCE -L$NP/lib "\$@" -lbsd -lnetwork -lgnu
EOF
	chmod +x $BIN/haiku-rust-$t
done

cat > bootstrap.toml <<EOF
change-id = "ignore"

[llvm]
# Must be false: when cross-building host tools, rustc_llvm rewrites the build
# host's llvm-config paths to the target's, which only works if both LLVMs are
# built locally the same way (see haiku-rust-bake for the full explanation).
download-ci-llvm = false
ninja = true
link-jobs = 4

[build]
build = "aarch64-unknown-linux-gnu"
host = ["$T"]
target = ["$T"]
docs = false
compiler-docs = false
extended = false
tools = ["rustdoc"]   # cargo is built separately (build-cargo.sh), linking system libcurl
locked-deps = true
vendor = false
jobs = $(nproc)

[rust]
channel = "nightly"
download-rustc = false
debug = false
debuginfo-level = 0
backtrace = true
incremental = false

[dist]
compression-formats = ["gz"]

[target.aarch64-unknown-linux-gnu]
cc = "gcc"
cxx = "g++"

[target.$T]
cc = "$BIN/haiku-rust-gcc"
cxx = "$BIN/haiku-rust-g++"
linker = "$BIN/haiku-rust-gcc"
ar = "$X/bin/aarch64-unknown-haiku-ar"
ranlib = "$X/bin/aarch64-unknown-haiku-ranlib"
crt-static = false
EOF

# stage0 is an upstream nightly that has never heard of this target.
export BOOTSTRAP_SKIP_TARGET_SANITY=1
python3 x.py build library --target $T
python3 x.py dist rustc rust-std

mkdir -p $OUT && cp build/dist/rustc-nightly-$T.tar.gz build/dist/rust-std-nightly-$T.tar.gz $OUT/
ls -la $OUT
