# kqueue support in eio_posix

Status: native kqueue implementation is available as an explicit opt-in. Poll
remains the default. Native macOS/FreeBSD CI must pass before changing that
policy or making performance claims.

The work is stacked on the private poller extraction, based on upstream
`1fa7762`. The scheduler, cancellation, timers, wake and signal pipes, thread
pool, filesystem, networking, and process implementations remain shared.

## Building and selecting the poller

On FreeBSD, macOS, and OpenBSD, the package depends on `kqueue >= 0.7.0`.
Other POSIX systems can build without the binding and keep using poll. Dune
selects the native adapter only when the binding is installed. The binding's
current event layout restricts this adapter to 64-bit little-endian systems.

```sh
opam install . --deps-only --with-test
EIO_BACKEND=posix EIO_POSIX_POLLER=poll dune runtest --force
EIO_BACKEND=posix EIO_POSIX_POLLER=kqueue dune runtest --force
```

`EIO_BACKEND=posix` selects Eio's shared POSIX backend. `EIO_POSIX_POLLER`
selects its multiplexer: `poll` or `kqueue`. If unset it selects poll. Invalid
values and explicitly requesting unavailable kqueue fail clearly; they do not
silently run poll. Tests declare the environment dependency to avoid cached
poll results being mistaken for a kqueue run.

## Implementation

- `poll_poller.ml` retains the existing Iomux poll implementation.
- `kqueue_poller.ml` owns kernel-independent registration bookkeeping.
- `kqueue_backend.available.ml` adapts kqueue-ml; the unavailable adapter keeps
  the poll build independent of that package.
- `poller.ml` selects the implementation behind the same private interface.

Each scheduler domain owns one close-on-exec kqueue. The adapter uses
level-triggered read/write filters and a fixed 256-event result buffer. Full
buffers are handled by subsequent waits. No edge-triggering, kernel timers,
`EVFILT_USER`, or changes to Eio's process signalling are introduced.

Every replacement gets a fresh integer cookie in `udata`. Dispatch checks that
cookie against the current registration, including between callbacks in one
batch. Closing/removing a descriptor or replacing its interests invalidates old
results. A stale second event cannot wake a new waiter for a reused FD number.
Registration updates use a separate changelist, so they cannot overwrite the
batch currently being dispatched.

The initial adapter recreates filters synchronously. A partially failed update
retires both filters before exposing the error. Missing filters during cleanup
are accepted because close/dup2 may already have removed them. Unexpected
cleanup failures prevent the scheduler from sleeping indefinitely on stale
kernel state. Future batching needs its own benchmarks and tests.

Rejected filters use the existing bounded worker fallback: select on macOS,
poll on other POSIX systems. Regular files and directories get unconditional
readiness, preserving poll semantics even at EOF. Kqueue EOF is directional;
buffered read data remains available. Socket errors in `fflags` fail only the
corresponding direction, so connection refusal is not mistaken for success.
An interrupted wait returns to the scheduler to reconsider timers and work.

## Validation

The deterministic suite covers stale batches, descriptor replacement,
remaining interests after cancellation, partially failed registration,
interrupted waits, pending fallback events, resource errors, cleanup, regular
files at EOF, buffered data with EOF, peer shutdown, and connection refusal.
Kernel-independent tests run with a controllable fake driver on all POSIX hosts.

Native CI is configured for macOS with both pollers and FreeBSD 14.3 with both
pollers. Linux retains poll coverage. Native runs are still required.

Local integration also exercises the adapter through kqueue-ml with a
Linux libkqueue compatibility build. This is additional coverage, not a native
BSD result. The full upstream suite has three environment restrictions here:
named Unix sockets and ownership changes fail in `tests/fd_passing.md`,
`tests/network.md`, and `tests/fs.md`. Unmodified upstream produces identical
corrected output for those files.

## QCheck programs and replay

The property suite adds 1,000 command programs against an independent
registration-identity model, plus 500 live-socket programs for poll and 500 for
kqueue when available. Commands cover interest replacement, failures after a
partial update, interruption, delayed batches, removal from inside a callback,
sending/draining socket data, and `dup2` descriptor replacement. Command lists shrink by removing interior
commands as well as chunks. QCheck is a test-only dependency.

```sh
dune exec lib_eio_posix/test/test_kqueue_properties.exe -- --seed 424242 --verbose
```

On Linux without native kqueue, all 1,500 model/poll programs pass. A mutation
check that disables generation validation is rejected and shrinks to two
registration changes; the original implementation was restored afterward.
Unavailable native properties are reported explicitly, and an explicit kqueue
request fails rather than silently skipping them.

The live kqueue socket property currently exposes an `ENOENT` on filter re-add
after `dup2` in the Linux libkqueue compatibility build. This may reflect its
emulation of automatic filter removal. The case remains enabled, unchanged,
for native CI; no native property-test pass is claimed.

## Performance gate and upstream path

Benchmark on a real FreeBSD host before changing the default. Use 100, 1,000,
and 10,000 established connections, with 1%, 10%, and 100% active. Record CPU,
throughput, p99 latency, allocations, connection churn, descriptor limits, OS,
compiler, Eio commit, and methodology. Keep application/build settings identical.

Keep the fork's default branch aligned with upstream and review the extraction,
native implementation, and property tests separately. Contact maintainers only
when explicitly asked.

This is readiness notification, not io_uring-style buffer selection,
asynchronous disk I/O, or transaction batching.

## Reproducible validation

The POSIX jobs use OCaml 5.4.0 on Ubuntu 24.04 and macOS 15. They check out
and record the PR head (rather than claiming a synthetic merge is the head),
build the whole workspace, and run the full suite with `--force`. Environment,
build, and test logs are uploaded even on failure. Run the same commands with:

```sh
bash .github/ci/posix.sh build
bash .github/ci/posix.sh test
```

A configured workflow is not evidence of execution. The unrestricted full-suite
requirement above remains open until a successful run is linked to its commit.

## Error and lifecycle hardening

Unsupported native filters may use the bounded worker fallback. Invalid
registrations (`EBADF` or `EINVAL`) instead fail the operation; they are not
interpreted as device capability failures. Unexpected non-OS exceptions escape
immediately and require the owner to close the poller. A failed kernel removal
poisons subsequent waits and retains the first failure and its backtrace.

The real-adapter regressions exercise active `dup2` reuse, replacement during
dispatch, 300 simultaneously ready sockets across result batches, repeated normal
and exceptional scheduler teardown, close-on-exec, and actual signal interruption.
Each case runs in a child supervised by a separate 15-second watchdog, so a stuck
poller cannot disable its own timeout. The device tests use a controlled PTY even
on hosts without a controlling terminal.

These tests run under the explicitly selected poller. Passing with Linux poll
validates the fixtures, not native kqueue. The `dup2` regression is not disabled
for libkqueue or native platforms; failures must be diagnosed rather than waived.

CI runs the properties with fixed seed 424242 and a fresh random seed separately
from the full suite, retaining both logs even if one fails. Reproduce with
`bash .github/ci/posix.sh properties`. Poll and kqueue use the same generator;
separate QCheck properties do not imply identical generated command sequences.

Full-suite CI runs clean the Dune build directory first. MDX examples mutate
filesystem fixtures, so `--force` alone is insufficient to isolate a second
poller run after a failed example. Logs are stored outside the build directory.
