include Poller_types

type t =
  | Poll of Poll_poller.t
  | Kqueue of Kqueue_backend.t

let kqueue_available = Kqueue_backend.available

let create ?backend () =
  let backend = match backend with
    | Some backend -> backend
    | None ->
      match Sys.getenv_opt "EIO_POSIX_POLLER" with
      | None | Some "poll" -> `Poll
      | Some "kqueue" -> `Kqueue
      | Some _ -> invalid_arg "EIO_POSIX_POLLER must be poll or kqueue"
  in
  match backend with
  | `Poll -> Poll (Poll_poller.create ())
  | `Kqueue ->
    if not kqueue_available then
      invalid_arg "kqueue poller is unavailable on this platform or was not built";
    Kqueue (Kqueue_backend.create ())

let close = function
  | Poll t -> Poll_poller.close t
  | Kqueue t -> Kqueue_backend.close t

let set t fd ~read ~write = match t with
  | Poll t -> Poll_poller.set t fd ~read ~write
  | Kqueue t -> Kqueue_backend.set t fd ~read ~write

let wait t timeout = match t with
  | Poll t -> Poll_poller.wait t timeout
  | Kqueue t -> Kqueue_backend.wait t timeout

let iter_ready t nready fn = match t with
  | Poll t -> Poll_poller.iter_ready t nready fn
  | Kqueue t -> Kqueue_backend.iter_ready t nready fn
