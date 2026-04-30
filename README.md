# hilang

A Smalltalk-flavored language and VM written in Zig, with a tracing
JIT for ARM64 (currently macOS Apple Silicon).

## Status

Experimental. The language and VM are usable end-to-end — there's a
bootstrap kernel, a Smalltalk-style class hierarchy with primitives,
a bytecode interpreter, a tracing JIT, a Cheney two-space copying GC,
inline caches (bimorphic), tier-up from bytecode to native, and a
client/server protocol over a Unix socket. Programs are submitted as
JSON ASTs against the daemon's `eval` and `define_method` requests.

## Platforms

The VM core compiles for any target Zig supports. The JIT emits raw
ARM64 instructions through Apple's `MAP_JIT` + `pthread_jit_write_protect_np`
mechanism, so JIT-backed dispatch is currently macOS Apple Silicon only.
On other platforms the bytecode interpreter still runs.

## Build

Requires Zig 0.16 or newer.

```sh
zig build                              # build the server + client
zig build -Doptimize=ReleaseFast       # release build
zig build test                         # run all tests (~4 s)
zig build bench-micros                 # 4-leg microbenchmarks
zig build bench-suite                  # extended workload suite
zig build bench                        # both
```

The server lives at `zig-out/bin/hilang-vm`, the client at
`zig-out/bin/hilang`.

## Run

Start the server (it listens on `/tmp/hilang.sock` by default):

```sh
./zig-out/bin/hilang-vm
```

Then talk to it from the client, or send JSON requests directly. The
protocol is documented by the handlers in
[src/server/main.zig](src/server/main.zig) — `eval`, `define_method`,
`define_class`, `inspect`, `methods`, `classes`, `gc`, `snapshot`.

## Layout

```
src/vm/        Language core: AST, bytecode, JIT, GC, kernel classes,
               primitives, image format. ~11k lines.
src/server/    Unix-socket daemon exposing the VM over JSON.
src/client/    CLI client for the daemon.
tests/         Zig integration tests (67 tests, in-process via the
               TestEnv harness in tests/harness.zig).
bench/         Microbenchmarks (micros.zig — fib/sum/alloc/count) and
               extended workload suite (suite.zig — 9 categories
               covering recursion, collections, strings, large-int
               math, GC pressure, polymorphism, backtracking,
               exceptions, Float math).
```

A few starting points to read:

- [src/vm/eval.zig](src/vm/eval.zig) — bytecode interpreter, send
  dispatch, tier-up gate, JIT entry helpers.
- [src/vm/jit.zig](src/vm/jit.zig) — ARM64 codegen, inline caches,
  W^X dance.
- [src/vm/gc.zig](src/vm/gc.zig) — Cheney collector with atomic
  rollback on OOM.
- [src/vm/stdlib.zig](src/vm/stdlib.zig) — kernel Smalltalk classes
  defined at bootstrap time.

## License

MIT. See [LICENSE](LICENSE).
