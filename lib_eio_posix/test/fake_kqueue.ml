module Types = Eio_posix__Poller_types
open Types

type raw_event = Unix.file_descr * int * event

type t = {
  registrations : (Unix.file_descr, int * bool * bool) Hashtbl.t;
  mutable events : raw_event list;
  mutable next_events : raw_event list option;
  mutable fail_update : exn option;
  mutable interrupt : bool;
  mutable last_timeout : timeout;
  mutable closes : int;
  mutable fail_close : exn option;
}

let latest = ref None
let classify = ref (fun _ -> `Native)

let create () =
  let t = { registrations = Hashtbl.create 8; events = []; next_events = None;
            fail_update = None; interrupt = false; last_timeout = Nowait; closes = 0; fail_close = None } in
  classify := (fun _ -> `Native);
  latest := Some t;
  t

let get () = Option.get !latest
let close t =
  t.closes <- t.closes + 1;
  match t.fail_close with Some ex -> raise ex | None -> ()
let kind fd = !classify fd

let update t fd ~token ~read ~write =
  (* Simulate an update which may fail after applying only its read filter. *)
  Hashtbl.replace t.registrations fd (token, read, false);
  begin match t.fail_update with
  | Some ex -> t.fail_update <- None; raise ex
  | None -> ()
  end;
  if not read && not write then Hashtbl.remove t.registrations fd
  else Hashtbl.replace t.registrations fd (token, read, write)

let snapshot t =
  Hashtbl.fold (fun fd (token, read, write) acc ->
      let acc = if write then (fd, token, Write) :: acc else acc in
      if read then (fd, token, Read) :: acc else acc
    ) t.registrations []
  |> List.sort (fun (fd1, _, e1) (fd2, _, e2) -> compare (fd1, e1) (fd2, e2))

let wait t timeout =
  t.last_timeout <- timeout;
  if t.interrupt then (
    t.interrupt <- false;
    raise (Unix.Unix_error (Unix.EINTR, "kevent", ""))
  );
  t.events <- Option.value t.next_events ~default:(snapshot t);
  t.next_events <- None;
  List.length t.events

let iter_ready t _nready fn =
  List.iter (fun (fd, token, event) -> fn fd ~token event) t.events

module Poller = Eio_posix__Kqueue_poller.Make (struct
  type nonrec t = t
  let create = create
  let close = close
  let kind = kind
  let update = update
  let wait = wait
  let iter_ready = iter_ready
end)

let fd = Iomux.Util.unix_of_fd

let with_poller fn =
  let poller = Poller.create () in
  Fun.protect ~finally:(fun () -> Poller.close poller) (fun () -> fn poller (get ()))

let collect poller n =
  let events = ref [] in
  Poller.iter_ready poller n (fun fd event -> events := (fd, event) :: !events);
  List.rev !events
