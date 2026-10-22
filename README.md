# aarch64-unknown-haiku

A Rust target for **Haiku on arm64**, and a Rust toolchain that runs **on**
Haiku arm64: `rustc`, `rust-std`, `rustdoc` and `cargo`.

Upstream Rust has Haiku targets for i686 and x86_64 only. This repo adds
`aarch64-unknown-haiku` (a 27-line patch to `rustc_target`) and cross-builds a
Haiku-hosted toolchain from aarch64 Linux.

| | |
|---|---|
| rustc | 1.101.0-nightly (`1a2c4797ef25`, 2026-10-22), LLVM 23.1.4 |
| cargo | 1.101.0 (`3960fa69bb61`) |
| Haiku | hrev60290 nightly (arm64), under UTM/QEMU on Apple Silicon |
| Binaries | [Releases](../../releases) |

## What works (all run natively on Haiku arm64)

- `rustc -vV` → `host: aarch64-unknown-haiku`
- `tests/stdcheck.rs`: threads, HashMap, files + `File::lock`, TCP,
  `std::process`, env/time, panic unwinding, 8/8
- `cargo new` + `cargo add serde --features derive serde_json` + `cargo run`.
  The proc-macro is built as a shared library and loaded into rustc on Haiku.
- `cargo install ripgrep` (rg 15.2.0, 1m28s on 8 vCPUs)

Experimental: one VM, one revision. `std` needed no changes; the `libc`
crate's Haiku aarch64 module is still a stub upstream (`mcontext_t`/`ucontext_t`
are missing), which nothing here has needed yet.

## Install (on Haiku arm64)

Requires OpenSSL 3, zlib and **libcurl with HTTP/2** for cargo. Builds of
those, plus OpenSSH, git and the clock and CA-certificate setup, are in
[haiku-arm64-bootstrap](https://github.com/bluevisor/haiku-arm64-bootstrap).

```sh
# on the Haiku machine, with the release assets in the current directory
mkdir x && for t in rustc-nightly-*.tar.gz rust-std-nightly-*.tar.gz; do python3 -m tarfile -e "$t" x/; done
P=/boot/system/non-packaged/rust; mkdir -p $P
cp -a x/rustc-nightly-aarch64-unknown-haiku/rustc/. \
      x/rust-std-nightly-aarch64-unknown-haiku/rust-std-aarch64-unknown-haiku/. $P/
rm -f $P/manifest.in
install -m 755 cargo-1.101.0-haiku-arm64 $P/bin/cargo
for b in rustc rustdoc cargo; do ln -sf ../rust/bin/$b /boot/system/non-packaged/bin/$b; done
rustc -vV
```

Unpack with Python's `tarfile` (or any tar) on Haiku itself. `rustc` finds its
libraries through `$ORIGIN/../lib`.

**Over ssh**, add Haiku's library paths to `sshd_config` or cargo's child
`rustc` dies with exit status 3 and no message (see below):

```
SetEnv LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib" ADDON_PATH="%A/add-ons:/boot/home/config/non-packaged/add-ons:/boot/home/config/add-ons:/boot/system/non-packaged/add-ons:/boot/system/add-ons"
```

## Build

From an **aarch64 Linux** host (a `debian:bookworm` container works) with the
Haiku arm64 cross toolchain and sysroot from haiku-arm64-bootstrap, and this
repo mounted at `/repo`:

```sh
bash /repo/scripts/build-rust.sh    # rustc + rust-std: ~35 min on 12 cores; give it ~28 GB RAM
bash /repo/scripts/build-cargo.sh   # cargo: ~3 min
```

`build-rust.sh` checks out rust-lang/rust at `RUST_COMMIT`, applies
`patches/rust-aarch64-unknown-haiku.patch`, writes `bootstrap.toml` and runs
`x.py build library` then `x.py dist rustc rust-std`. `build-cargo.sh` builds
cargo standalone against the system libcurl/OpenSSL/zlib, as x.py's
`all-static` cargo would try to compile OpenSSL for an unknown target.

## Things that broke, and why

- **The target**: the AArch64 ELF data layout from `aarch64-unknown-freebsd`,
  plus `base::haiku::opts()`, `+v8a`, inline stack probes and PIE (Haiku
  executables are ET_DYN, as on x86_64 Haiku).
- **`BOOTSTRAP_SKIP_TARGET_SANITY=1`**: stage0 is an upstream nightly that has
  never heard of the target, and bootstrap checks against its list.
- **`download-ci-llvm = false`**: a cross-hosted rustc's `rustc_llvm` build
  rewrites the build host's `llvm-config` paths to the target's. That only
  works when both LLVMs are built locally the same way.
- **`ld: cannot find -lgcc_s`** linking `libstd.so`: Haiku's cross toolchain
  builds only a static libgcc. Put the `gcc_syslibs` + `gcc_syslibs_devel`
  packages in the sysroot.
- **Linker wrapper**: `-lbsd -lnetwork -lgnu` after rustc's objects (BSD,
  socket and glibc-compat functions live outside libroot on Haiku).
- **`x.py dist` wipes `build/host/stage1/bin` when it starts.** Snapshot stage1
  before using it for a cargo build that runs in parallel.
- **cargo needs HTTP/2 in libcurl**: it enables curl's `http2` feature, and
  curl-sys otherwise compiles its own static curl.
- **cargo's child rustc exits with status 3 over ssh.** cargo prepends to
  `LIBRARY_PATH`; sshd sessions start with it empty, and on Haiku a set
  `LIBRARY_PATH` *replaces* the runtime loader's default search path. Hence
  the `SetEnv` above.
- **Use a nightly ≥ 2026-10-13**: before that, `File::lock` returned
  `Unsupported` on Haiku and cargo silently ran without its file locks
  (rust-lang/rust#164031).

## Prior art

Two projects did this before, and this repo follows their approach:

- [felipedbene/Haiku-Graviton](https://github.com/felipedbene/Haiku-Graviton):
  `graviton/scripts/haiku-rust-bake`, a Haiku-hosted rustc + cargo for DeBeOS
  on AWS Graviton, with the reasoning for each build choice written out.
- [rainygirl/renkuos-rchromium-arm64](https://github.com/rainygirl/renkuos-rchromium-arm64):
  `rust/`, the target spec and a std cross-build, made to port Chromium.

## Upstreaming

The patch is the shape of a Tier 3 target addition to rust-lang/rust, which
also needs a named target maintainer and a `src/doc/rustc/src/platform-support`
entry. A `mod aarch64` for Haiku in rust-lang/libc would belong there.

## License

MIT OR Apache-2.0, like Rust (`LICENSE-MIT`, `LICENSE-APACHE`).
