(** Registration generations and readiness dispatch for one scheduler domain.

    Each non-empty [set] creates a fresh generation. Native and synthetic events
    are delivered only while that generation is current; callbacks may change
    registrations, so this is checked separately for every event.

    Synthetic readiness persists until the registration changes. [wait] takes
    a snapshot without consuming it, then waits on the kernel with a zero
    timeout if synthetic events exist. If the wait raises, the caller must
    dispatch zero events; a later wait retries the pending synthetic events.

    Failed OS updates retire both filters before reporting a per-operation
    error. Failed retirement poisons the poller: the next wait raises the first
    cleanup error with its original backtrace. Unexpected non-OS exceptions
    propagate immediately; the owner must close the poller rather than reuse it.
    [close] is idempotent, including after a failed close. *)
module type Kernel = sig
  type t
  val create : unit -> t
  val close : t -> unit
  val kind : Unix.file_descr -> [ `Native | `Ready | `Unsupported ]
  (** Regular files need unconditional readiness, unlike EVFILT_READ at EOF. *)

  val update : t -> Unix.file_descr -> token:int -> read:bool -> write:bool -> unit
  (** Replace both interests and their cookie. An update may fail after applying
      one filter; a subsequent empty update must retire both. Empty updates must
      tolerate filters already removed by close/dup2. *)

  val wait : t -> Poller_types.timeout -> int
  val iter_ready : t -> int -> (Unix.file_descr -> token:int -> Poller_types.event -> unit) -> unit
  (** Updates from the callback must not overwrite the returned readiness batch. *)
end

module Make (_ : Kernel) : sig
  type t
  val create : unit -> t
  val close : t -> unit
  val set : t -> Unix.file_descr -> read:bool -> write:bool -> unit
  val wait : t -> Poller_types.timeout -> int
  val iter_ready : t -> int -> (Unix.file_descr -> Poller_types.event -> unit) -> unit
end
