#!/usr/bin/env bash
# Run from the repository root, with the selected opam switch in the environment.
set -euo pipefail
export EIO_BACKEND=posix
export EIO_POSIX_POLLER=${EIO_POSIX_POLLER:-poll}
mkdir -p ci-logs
# The real-kernel batch regression needs more than 256 socket pairs.
ulimit -n 2048

case ${1:-} in
  build)
    {
      git rev-parse HEAD
      uname -a
      if command -v sw_vers >/dev/null; then sw_vers; fi
      if command -v freebsd-version >/dev/null; then freebsd-version -ku; fi
      printf 'EIO_BACKEND=%s EIO_POSIX_POLLER=%s\n' "$EIO_BACKEND" "$EIO_POSIX_POLLER"
      printf 'descriptor limit: '; ulimit -n
      opam exec -- ocamlc -version
      opam exec -- dune --version
      opam list --installed --columns=name,version
    } 2>&1 | tee ci-logs/environment.log
    opam exec -- dune build @all 2>&1 | tee ci-logs/build.log
    ;;
  test)
    # MDX examples mutate their working directories. --force alone does not
    # remove fixtures left behind by a previous poller or a failing example.
    opam exec -- dune clean
    opam exec -- dune runtest --force 2>&1 | tee "ci-logs/tests-$EIO_POSIX_POLLER.log"
    ;;
  *) printf 'Usage: %s build|test\n' "$0" >&2; exit 2 ;;
esac
