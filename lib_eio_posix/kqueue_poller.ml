(* Kernel-independent registration bookkeeping, also exercised with a fake
   kernel in the model tests. One scheduler domain owns each instance. *)

open Poller_types

module type Kernel = sig
  type t
  val create : unit -> t
  val close : t -> unit
  val kind : Unix.file_descr -> [ `Native | `Ready | `Unsupported ]
  val update : t -> Unix.file_descr -> token:int -> read:bool -> write:bool -> unit
  val wait : t -> timeout -> int
  val iter_ready : t -> int -> (Unix.file_descr -> token:int -> event -> unit) -> unit
end

module Make (Kernel : Kernel) = struct
  type registration = {
    token : int;
    read : bool;
    write : bool;
    native : bool;
  }

  type t = {
    kernel : Kernel.t;
    registrations : (Unix.file_descr, registration) Hashtbl.t;
    pending : (Unix.file_descr * int * event) Queue.t;
    mutable synthetic : (Unix.file_descr * int * event) list;
    mutable native_count : int;
    mutable next_token : int;
    mutable fatal : (exn * Printexc.raw_backtrace) option;
    mutable closed : bool;
  }

  let create () =
    let kernel = Kernel.create () in
    try {
      kernel; registrations = Hashtbl.create 16; pending = Queue.create ();
      synthetic = []; native_count = 0; next_token = 0; fatal = None; closed = false;
    } with ex ->
      let bt = Printexc.get_raw_backtrace () in
      (* Report both failures using the same exception aggregation as Eio. *)
      let ex, bt = match Kernel.close kernel with
        | () -> ex, bt
        | exception cleanup ->
          Eio.Exn.combine (ex, bt) (cleanup, Printexc.get_raw_backtrace ())
      in
      Printexc.raise_with_backtrace ex bt

  let ensure_open t =
    if t.closed then invalid_arg "kqueue poller is closed"

  let close t =
    if not t.closed then (
      t.closed <- true;
      Hashtbl.clear t.registrations;
      Queue.clear t.pending;
      t.synthetic <- [];
      Kernel.close t.kernel
    )

  let remove_kernel t fd =
    try Kernel.update t.kernel fd ~token:0 ~read:false ~write:false
    with Unix.Unix_error _ as ex ->
      (* An uncertain kernel state must never be used for another wait.
         Preserve the first failure, including where it occurred. *)
      if t.fatal = None then
        t.fatal <- Some (ex, Printexc.get_raw_backtrace ())

  let unsupported = function
    | Unix.Unix_error ((Unix.ENODEV | ENOSYS | EPERM
                      | EOPNOTSUPP), _, _) -> true
    | _ -> false

  let set t fd ~read ~write =
    ensure_open t;
    let old = Hashtbl.find_opt t.registrations fd in
    if not read && not write then (
      Hashtbl.remove t.registrations fd;
      match old with
      | Some { native = true; _ } -> remove_kernel t fd
      | _ -> ()
    ) else (
      if t.next_token = max_int then failwith "kqueue registration token exhausted";
      t.next_token <- t.next_token + 1;
      let token = t.next_token in
      let pending event =
        Hashtbl.replace t.registrations fd { token; read; write; native = false };
        Queue.add (fd, token, event) t.pending
      in
      match Kernel.kind fd with
      | (`Ready | `Unsupported) as kind ->
        begin match old with
        | Some { native = true; _ } -> remove_kernel t fd
        | _ -> ()
        end;
        pending (if kind = `Ready then Read_write else Unpollable)
      | `Native ->
        begin match Kernel.update t.kernel fd ~token ~read ~write with
        | () -> Hashtbl.replace t.registrations fd { token; read; write; native = true }
        | exception (Unix.Unix_error _ as ex) ->
          (* A multi-filter update can fail after installing its first filter.
             Retire both before exposing the rejection to the waiting fibers. *)
          remove_kernel t fd;
          pending (if unsupported ex then Unpollable else Error ex)
        end
      | exception (Unix.Unix_error _ as ex) ->
        begin match old with
        | Some { native = true; _ } -> remove_kernel t fd
        | _ -> ()
        end;
        pending (if unsupported ex then Unpollable else Error ex)
    )

  let is_current t fd token =
    match Hashtbl.find_opt t.registrations fd with
    | Some r when r.token = token -> true
    | _ -> false

  let wait t timeout =
    ensure_open t;
    begin match t.fatal with
    | Some (ex, bt) -> Printexc.raise_with_backtrace ex bt
    | None -> ()
    end;
    t.synthetic <- [];
    t.native_count <- 0;
    (* Only rejected registrations are in this queue. Normal waits inspect ready
       events, never all registered descriptors. Retain live synthetic events
       until their waiter is removed, including when a native wait gets EINTR. *)
    for _ = 1 to Queue.length t.pending do
      let (fd, token, _) as item = Queue.take t.pending in
      if is_current t fd token then (
        Queue.add item t.pending;
        t.synthetic <- item :: t.synthetic
      )
    done;
    t.synthetic <- List.rev t.synthetic;
    let timeout = if t.synthetic = [] then timeout else Nowait in
    let n = Kernel.wait t.kernel timeout in
    t.native_count <- n;
    n + List.length t.synthetic

  let iter_ready t nready fn =
    ensure_open t;
    (* The scheduler passes zero after an interrupted wait. In particular, do
       not dispatch an old event buffer or consume pending fallback events. *)
    if nready <> 0 then (
      let dispatch fd ~token event =
        match Hashtbl.find_opt t.registrations fd with
        | Some r when r.token = token ->
          begin match event with
          | Read | Read_error _ when not r.read -> ()
          | Write | Write_error _ when not r.write -> ()
          | _ -> fn fd event
          end
        | _ -> ()
      in
      List.iter (fun (fd, token, event) -> dispatch fd ~token event) t.synthetic;
      Kernel.iter_ready t.kernel t.native_count dispatch
    )
end
