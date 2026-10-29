let available = false

type t = unit

let unavailable () = invalid_arg "kqueue poller is unavailable in this build"
let create () = unavailable ()
let close () = ()
let set () _fd ~read:_ ~write:_ = unavailable ()
let wait () _timeout = unavailable ()
let iter_ready () _nready _fn = unavailable ()
