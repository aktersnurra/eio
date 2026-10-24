# kqueue support in eio_posix

Status: the poller boundary is extracted and scheduler regression tests are
added. This branch still uses `poll`; there is no kqueue implementation or
performance claim yet.

Base: upstream commit `1fa7762`, inspected on 2026-10-24.

## Repository and scope

Develop this in a fork of `ocaml-multicore/eio`, on branch `kqueue`.
Keep the fork's default branch aligned with upstream so that each implementation
step can be reviewed and proposed upstream independently.

The goal is a native kqueue multiplexer within `eio_posix`. Reuse its scheduler,
fiber cancellation, timers, thread pool, filesystem, networking, and process
implementations. A separate `eio-kqueue` package is not required for this scope.

## First implementation change: isolate the existing poller

`lib_eio_posix/poller.ml` now owns the `Iomux.Poll.t` and its highest populated
index. Its private interface in `poller.mli` provides:

- Create and close a poller.
- Set a descriptor's read/write interests; empty interests remove it.
- Wait with an infinite, zero, or nanosecond timeout.
- Deliver ready descriptors with independent read, write, and unpollable results.

Waiter lists and continuation management remain in the scheduler. The poll
adapter preserves the existing handling of `POLLHUP`, `POLLERR`, and `POLLNVAL`.
Both the domain wake pipe and `Signal_fd` are monitored through the same
interface. Upstream EINTR handling for wake-pipe reads and writes is retained.

`Iomux.Poll` remains the only implementation. The POSIX suite must pass before
adding kqueue. CI explicitly selects the POSIX backend on Linux and macOS.

Verification on Linux with OCaml 5.4.0:

- `dune build @all` passes.
- `dune runtest lib_eio_posix` passes, including all seven new scheduler tests.
- `make test_posix` reaches three existing Markdown test failures involving
  named Unix sockets and ownership changes denied by the execution environment.
  Unmodified upstream `1fa7762` produces the same three failures with identical
  corrected output. A complete suite run on an unrestricted host is still needed.

## Second implementation change: add kqueue

Evaluate existing OCaml kqueue bindings against the private poller interface
before choosing a dependency. Check runtime-lock handling, timeout precision,
close-on-exec support, event-buffer ownership, and FreeBSD compatibility.

Start with level-triggered `EVFILT_READ` and `EVFILT_WRITE`. Keep the existing
wake and signal pipes; do not introduce `EVFILT_USER`, edge-triggered semantics,
or changes to process signalling in this patch.

Important invariants:

- Cancelled fibers must not retain kernel interests after their last waiter is
  removed. Cancelling a reader must preserve any remaining writer interest.
- Closing a descriptor removes kqueue registrations automatically. Reusing its
  integer must establish fresh registrations.
- An event already returned in a batch must not wake a waiter registered later
  for a reused descriptor. Define registration identity and stale-event handling
  explicitly before implementation.
- Read and write filters can produce separate events for one descriptor in the
  same batch. Dispatch must tolerate a preceding event removing its waiter entry.
- EOF and socket failures must resume the relevant waiters so the actual I/O
  operation can report the result. Change errors (`EV_ERROR`) must be handled
  separately from readiness.
- Return from an interrupted wait to the scheduler to reconsider timers and
  runnable work; do not restart the original timeout unconditionally.
- Each scheduler owns and closes its poller, including on exceptional exit.

Keep the poll fallback available on all current POSIX platforms. Add an explicit
test selection mechanism so CI and benchmarks can exercise both pollers on the
same BSD/macOS host. An explicitly requested unavailable poller should fail
clearly. Automatic selection policy can follow native validation.

## Validation gates

1. Run the existing POSIX suite with the extracted poll adapter.
2. Add focused regressions for cancellation with remaining waiters, simultaneous
   read/write readiness, close and descriptor reuse, stale events, EOF, socket
   errors, and repeated scheduler creation and teardown.
3. Run the existing timer, signal, process, and cross-domain wakeup tests under
   both implementations on FreeBSD and macOS. Retain Linux poll coverage.
4. Benchmark on a real FreeBSD host before claiming a performance improvement.

Use 100, 1,000, and 10,000 established connections, with 1%, 10%, and 100% active.
Record CPU, throughput, p99 latency, allocations, and connection churn; keep the
application, workload, and build settings identical between runs. Report OS,
compiler, Eio commit, descriptor limit, and benchmark methodology with results.

## Upstream path

Prepare a short design discussion describing the private poller boundary and
the existing prototype history. Contact maintainers only when explicitly asked.
Propose the extraction and kqueue implementation separately if that makes review
easier. Do not publish an additional runtime package before resolving whether
the integration belongs in `eio_posix`.

This work changes readiness notification. It does not provide io_uring-style
buffer selection, asynchronous disk I/O, or transaction batching.
