(** Private readiness multiplexer for the POSIX scheduler.

    A poller is owned by one scheduler domain. Registration, waiting, dispatch,
    and cleanup must all happen in that domain. *)

type t

type timeout =
  | Infinite
  | Nowait
  | Nanoseconds of int64

type event =
  | Read
  | Write
  | Read_write
  | Unpollable
(** Hangups and errors are reported as [Read_write], allowing the I/O operation
    to discover EOF or the error. [Unpollable] asks the scheduler to use its
    existing fallback for descriptors that the multiplexer cannot monitor. *)

val create : unit -> t
val close : t -> unit
(** Release the poller's resources. The poll implementation owns no kernel
    resources, but other implementations may do so. *)

val set : t -> Unix.file_descr -> read:bool -> write:bool -> unit
(** Replace a descriptor's interests. Setting both to [false] removes it.
    The caller retains ownership of the descriptor. *)

val wait : t -> timeout -> int
(** Wait for readiness and return a batch size for {!iter_ready}.
    [Unix.Unix_error] exceptions, including [EINTR], are left to the scheduler. *)

val iter_ready : t -> int -> (Unix.file_descr -> event -> unit) -> unit
(** Dispatch the most recent batch, before the next call to {!wait}.
    The callback may update registrations using {!set}. *)
