(** Private readiness multiplexer for the POSIX scheduler.

    A poller is owned by one scheduler domain. Registration, waiting, dispatch,
    and cleanup must all happen in that domain. *)

type t

type timeout = Poller_types.timeout =
  | Infinite
  | Nowait
  | Nanoseconds of int64

type event = Poller_types.event =
  | Read
  | Write
  | Read_write
  | Unpollable
  | Error of exn
  | Read_error of exn
  | Write_error of exn
(** Poll hangups/errors are [Read_write]; kqueue EOF remains directional.
    The resumed I/O operation discovers EOF or the socket error. [Unpollable]
    uses the poll/select fallback. [Error ex] fails the waiting operation
    when registration fails for a reason other than an unsupported descriptor.
    [Read_error] and [Write_error] fail only waiters in that direction. *)

val kqueue_available : bool

val create : ?backend:[ `Poll | `Kqueue ] -> unit -> t
(** Defaults to [EIO_POSIX_POLLER], or poll if unset. Explicit kqueue selection
    fails on unsupported builds/platforms; it never silently falls back. *)

val close : t -> unit
(** Release the poller's resources. The poll implementation owns no kernel
    resources, but other implementations may do so. *)

val set : t -> Unix.file_descr -> read:bool -> write:bool -> unit
(** Replace a descriptor's interests. Setting both to [false] removes it.
    The caller retains ownership of the descriptor. *)

val wait : t -> timeout -> int
(** Wait for readiness and return a batch size for {!iter_ready}.
    [Unix.Unix_error] exceptions, including [EINTR], are left to the scheduler.
    After a failed wait, dispatch zero events; only a successful later wait may
    provide another batch. *)

val iter_ready : t -> int -> (Unix.file_descr -> event -> unit) -> unit
(** Dispatch the most recent batch, before the next call to {!wait}.
    The callback may update registrations using {!set}. *)
