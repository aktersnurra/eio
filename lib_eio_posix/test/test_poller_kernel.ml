(* Exercise the real adapters, including kernel behavior the fake cannot model.
   Each case runs in a child with a watchdog outside the scheduler under test. *)
module P = Eio_posix__Poller
open Eio_posix__Poller_types

let with_poller backend fn =
  let p = P.create ~backend () in
  Fun.protect ~finally:(fun () -> P.close p) (fun () -> fn p)

let with_socketpair fn =
  let a, b = Unix.(socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0) in
  Fun.protect ~finally:(fun () -> Unix.close a; Unix.close b) @@ fun () ->
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  fn a b

let send fd =
  assert (Unix.single_write fd (Bytes.of_string "!") 0 1 = 1)

let collect p =
  let seen = ref [] in
  let n = P.wait p Nowait in
  P.iter_ready p n (fun fd event -> seen := (fd, event) :: !seen);
  List.rev !seen

let active_reuse backend = with_poller backend @@ fun p ->
  with_socketpair @@ fun fd _old_peer ->
  P.set p fd ~read:true ~write:true;
  ignore (P.wait p Nowait : int);
  let replacement, peer = Unix.(socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0) in
  Fun.protect ~finally:(fun () -> Unix.close peer) @@ fun () ->
  (* Match the generated reuse case: close the temporary source after dup2,
     without deregistering the original descriptor before replacing it. *)
  Fun.protect ~finally:(fun () -> Unix.close replacement) (fun () ->
      Unix.set_nonblock replacement;
      Unix.dup2 ~cloexec:true replacement fd);
  P.set p fd ~read:true ~write:true;
  assert (collect p = [fd, Write]);
  P.set p fd ~read:true ~write:false;
  assert (collect p = []);
  send peer;
  assert (collect p = [fd, Read]);
  P.set p fd ~read:false ~write:false;
  assert (collect p = [])

let replace_during_dispatch backend = with_poller backend @@ fun p ->
  with_socketpair @@ fun fd peer ->
  with_socketpair @@ fun replacement replacement_peer ->
  send peer;
  send replacement_peer;
  P.set p fd ~read:true ~write:true;
  let n = P.wait p Nowait in
  let callbacks = ref 0 in
  P.iter_ready p n (fun got _ ->
      assert (got = fd);
      incr callbacks;
      assert (!callbacks = 1);
      Unix.dup2 ~cloexec:true replacement fd;
      P.set p fd ~read:true ~write:false
    );
  assert (!callbacks = 1);
  assert (collect p = [fd, Read])

let multiple_batches backend = with_poller backend @@ fun p ->
  let descriptors = ref [] in
  Fun.protect ~finally:(fun () -> List.iter Unix.close !descriptors) @@ fun () ->
  let unseen = Hashtbl.create 300 in
  for _ = 1 to 300 do
    let a, b = Unix.(socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0) in
    descriptors := a :: b :: !descriptors;
    send b;
    Hashtbl.add unseen a ();
    P.set p a ~read:true ~write:false
  done;
  let rec drain remaining_batches =
    if Hashtbl.length unseen > 0 then (
      assert (remaining_batches > 0);
      let n = P.wait p Nowait in
      assert (n > 0);
      P.iter_ready p n (fun fd event ->
          assert (event = Read);
          assert (Hashtbl.mem unseen fd);
          Hashtbl.remove unseen fd;
          P.set p fd ~read:false ~write:false
        );
      drain (remaining_batches - 1)
    )
  in
  drain 300;
  assert (collect p = [])

let open_descriptors () =
  let directory = if Sys.file_exists "/proc/self/fd" then "/proc/self/fd" else "/dev/fd" in
  Sys.readdir directory
  |> Array.to_list
  |> List.filter_map int_of_string_opt
  (* The directory descriptor used by readdir has already been closed. *)
  |> List.filter (fun fd ->
      match Unix.fstat (Iomux.Util.unix_of_fd fd) with
      | _ -> true
      | exception Unix.Unix_error (Unix.EBADF, _, _) -> false)
  |> List.sort compare

exception Expected

let lifecycle backend =
  (* Initialise singleton signal machinery before measuring owned resources. *)
  Eio_posix.run (fun _ -> ());
  let before = open_descriptors () in
  for _ = 1 to 100 do
    with_poller backend (fun _ -> ());
    begin try
      with_poller backend (fun _ -> raise Expected)
    with Expected -> () end;
    Eio_posix.run (fun _ -> ());
    begin try Eio_posix.run (fun _ -> raise Expected) with Expected -> () end
  done;
  assert (open_descriptors () = before)

let close_on_exec backend =
  let before = open_descriptors () in
  with_poller backend @@ fun _ ->
  let owned = List.filter (fun fd -> not (List.mem fd before)) (open_descriptors ()) in
  begin match backend with `Kqueue -> assert (List.length owned = 1) | `Poll -> assert (owned = []) end;
  List.iter (fun fd ->
      let args = [|Sys.executable_name; "--assert-closed"; string_of_int fd|] in
      let child = Unix.create_process Sys.executable_name args Unix.stdin Unix.stdout Unix.stderr in
      let _, status = Unix.waitpid [] child in
      assert (status = Unix.WEXITED 0)
    ) owned

let interrupted_wait backend = with_poller backend @@ fun p ->
  let old = Sys.signal Sys.sigusr1 (Sys.Signal_handle ignore) in
  Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigusr1 old) @@ fun () ->
  let parent = Unix.getpid () in
  let child = Unix.fork () in
  if child = 0 then (
    (* Repeat so a signal delivered immediately before wait cannot make the
       test silently miss the interruption. The wait also has a finite bound. *)
    for _ = 1 to 10 do
      Unix.sleepf 0.01;
      Unix.kill parent Sys.sigusr1
    done;
    Unix._exit 0
  );
  Fun.protect ~finally:(fun () ->
      (try Unix.kill child Sys.sigkill
       with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
      let rec reap () =
        match Unix.waitpid [] child with
        | _ -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
      in reap ()) @@ fun () ->
  begin match P.wait p (Nanoseconds 1_000_000_000L) with
  | _ -> failwith "wait did not report EINTR"
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
  end;
  P.iter_ready p 0 (fun _ _ -> failwith "interrupted wait dispatched an event");
  assert (collect p = [])

let run name fn =
  flush_all ();
  match Unix.fork () with
  | 0 ->
    begin try fn (); Unix._exit 0 with ex ->
      Printf.eprintf "%s: %s\n%s%!" name (Printexc.to_string ex) (Printexc.get_backtrace ());
      Unix._exit 1
    end
  | pid ->
    let deadline = Unix.gettimeofday () +. 15.0 in
    let rec wait () =
      match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.01; wait ()
      | 0, _ ->
        Unix.kill pid Sys.sigkill;
        ignore (Unix.waitpid [] pid);
        failwith (name ^ ": watchdog timeout")
      | _, Unix.WEXITED 0 -> Printf.printf "%s: ok\n%!" name
      | _ -> failwith (name ^ ": child failed")
    in wait ()

let () =
  Printexc.record_backtrace true;
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--assert-closed" then (
    let fd = Iomux.Util.unix_of_fd (int_of_string Sys.argv.(2)) in
    match Unix.fstat fd with
    | _ -> failwith "poller descriptor survived exec"
    | exception Unix.Unix_error (Unix.EBADF, _, _) -> ()
  ) else (
    let backend = match Sys.getenv_opt "EIO_POSIX_POLLER" with
      | None | Some "poll" -> `Poll
      | Some "kqueue" -> `Kqueue
      | Some _ -> invalid_arg "unknown poller"
    in
    (* Explicit native selection must fail even if a test would otherwise skip. *)
    with_poller backend ignore;
    List.iter (fun (name, test) -> run name (fun () -> test backend)) [
      "active descriptor replacement", active_reuse;
      "replacement during dispatch", replace_during_dispatch;
      "readiness across multiple batches", multiple_batches;
      "normal and exceptional lifecycle", lifecycle;
      "close-on-exec", close_on_exec;
      "native interrupted wait", interrupted_wait;
    ]
  )
