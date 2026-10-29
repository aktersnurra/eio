val available : bool

type t

val create : unit -> t
val close : t -> unit
val set : t -> Unix.file_descr -> read:bool -> write:bool -> unit
val wait : t -> Poller_types.timeout -> int
val iter_ready : t -> int -> (Unix.file_descr -> Poller_types.event -> unit) -> unit
