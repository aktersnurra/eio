open Poller_types

(* kqueue-ml's event layout currently assumes 64-bit little-endian fields. *)
let available = Kqueue.is_available && Sys.word_size = 64 && not Sys.big_endian

module Kernel = struct
  type t = {
    queue : Kqueue.t;
    changes : Kqueue.Event_list.t;
    events : Kqueue.Event_list.t;
  }

  let create () =
    let queue = Kqueue.create () in
    try { queue; changes = Kqueue.Event_list.create 1;
                events = Kqueue.Event_list.create 256 }
    with ex ->
      let bt = Printexc.get_raw_backtrace () in
      (* Report both failures using the same exception aggregation as Eio. *)
      let ex, bt = match Kqueue.close queue with
        | () -> ex, bt
        | exception cleanup ->
          Eio.Exn.combine (ex, bt) (cleanup, Printexc.get_raw_backtrace ())
      in
      Printexc.raise_with_backtrace ex bt

  let close t = Kqueue.close t.queue

  let rec kind fd =
    (* EVFILT_READ on a regular file at EOF may never fire; poll/select report
       regular files ready unconditionally. Preserve that contract, and use
       the bounded worker fallback for device-specific filters too. *)
    match (Unix.fstat fd).Unix.st_kind with
    | Unix.S_SOCK | S_FIFO -> `Native
    | S_REG | S_DIR -> `Ready
    | _ -> `Unsupported
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> kind fd

  let change t fd filter flags token =
    let rec submit () =
      Kqueue.Event_list.clear t.changes;
      Kqueue.Event_list.add_event t.changes ~ident:(Iomux.Util.fd_of_unix fd)
        ~filter ~flags ~fflags:Kqueue.Note.empty ~data:0 ~udata:token;
      match Kqueue.kevent t.queue ~changelist:t.changes
              ~eventlist:Kqueue.Event_list.null Kqueue.Timeout.immediate with
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> submit ()
      | exception Unix.Unix_error (error, name, _) ->
        let context = Printf.sprintf "fd=%d filter=%d flags=%d"
            (Iomux.Util.fd_of_unix fd) filter flags in
        raise (Unix.Unix_error (error, name, context))
    in
    submit ()

  let update t fd ~token ~read ~write =
    let update_filter filter enabled =
      (* Establish a fresh filter for this registration generation. Removal
         is idempotent when close/dup2 already deleted the kernel filter.
         Level triggering makes the remove/add interval safe: add reevaluates
         readiness, so no edge is lost. Batching is a later optimization. *)
      begin try change t fd filter Kqueue.Flag.delete 0
      with Unix.Unix_error ((Unix.ENOENT | EBADF), _, _) -> ()
      end;
      if enabled then change t fd filter Kqueue.Flag.add token
    in
    update_filter Kqueue.Filter.read read;
    update_filter Kqueue.Filter.write write

  let wait t timeout =
    let timeout = match timeout with
      | Infinite -> Kqueue.Timeout.never
      | Nowait -> Kqueue.Timeout.immediate
      | Nanoseconds ns -> Kqueue.Timeout.of_ns (Int64.max 0L ns)
    in
    (* Registration calls use a separate changelist and no output buffer, so
       updates made during dispatch cannot overwrite this readiness batch. *)
    Kqueue.kevent t.queue ~changelist:Kqueue.Event_list.null ~eventlist:t.events timeout

  let iter_ready t nready fn =
    if nready <> 0 then
      Kqueue.Event_list.iter_events t.events
        ~f:(fun ~ident ~filter ~flags ~fflags ~data ~udata ->
          let fd = Iomux.Util.unix_of_fd ident in
          let error code = Unix.Unix_error (error_of_errno code, "kevent", "") in
          let event =
            if Kqueue.Flag.intersect flags Kqueue.Flag.error then Error (error data)
            else if Kqueue.Filter.equal filter Kqueue.Filter.read then (
              (* EOF can coexist with buffered data. Let reads consume that
                 data before reporting the directional socket error. *)
              if Kqueue.Flag.intersect flags Kqueue.Flag.eof && fflags <> 0 && data <= 0
              then Read_error (error fflags)
              else Read
            ) else if Kqueue.Filter.equal filter Kqueue.Filter.write then (
              if Kqueue.Flag.intersect flags Kqueue.Flag.eof && fflags <> 0
              then Write_error (error fflags)
              else Write
            ) else failwith "kqueue returned an unexpected filter"
          in
          fn fd ~token:udata event
        )
end

include Kqueue_poller.Make (Kernel)
