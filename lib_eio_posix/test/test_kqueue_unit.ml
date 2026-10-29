module Fake = Kqueue_test_support.Fake_kqueue
module P = Fake.Poller
open Eio_posix__Poller_types

let stale_batch () = Fake.with_poller @@ fun p _kernel ->
  let fd = Fake.fd 10 in
  P.set p fd ~read:true ~write:true;
  let n = P.wait p Nowait in
  let seen = ref [] in
  P.iter_ready p n (fun fd event ->
      seen := event :: !seen;
      P.set p fd ~read:false ~write:false;
      P.set p fd ~read:false ~write:true
    );
  assert (!seen = [Read]);
  assert (Fake.collect p (P.wait p Nowait) = [fd, Write])

let remaining_direction () = Fake.with_poller @@ fun p _kernel ->
  let fd = Fake.fd 10 in
  P.set p fd ~read:true ~write:true;
  P.set p fd ~read:false ~write:true;
  assert (Fake.collect p (P.wait p Nowait) = [fd, Write])

let registration_rejection () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  kernel.fail_update <- Some (Unix.Unix_error (Unix.EPERM, "kevent", ""));
  P.set p fd ~read:true ~write:true;
  assert (Hashtbl.length kernel.registrations = 0);
  assert (Fake.collect p (P.wait p Infinite) = [fd, Unpollable]);
  assert (kernel.last_timeout = Nowait);
  P.set p fd ~read:false ~write:false;
  assert (P.wait p Nowait = 0)

let registration_error () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  let error = Unix.Unix_error (Unix.ENOMEM, "kevent", "") in
  kernel.fail_update <- Some error;
  P.set p fd ~read:true ~write:true;
  assert (Hashtbl.length kernel.registrations = 0);
  match Fake.collect p (P.wait p Infinite) with
  | [got_fd, Error ex] -> assert (got_fd = fd && ex = error)
  | _ -> assert false

let interrupted_wait () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  Fake.classify := (fun _ -> `Unsupported);
  P.set p fd ~read:true ~write:false;
  kernel.interrupt <- true;
  begin match P.wait p Infinite with
  | _ -> assert false
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
  end;
  assert (Fake.collect p 0 = []);
  assert (Fake.collect p (P.wait p Infinite) = [fd, Unpollable])

let removed_pending () = Fake.with_poller @@ fun p _kernel ->
  let fd = Fake.fd 10 in
  Fake.classify := (fun _ -> `Unsupported);
  P.set p fd ~read:true ~write:false;
  let n = P.wait p Nowait in
  P.set p fd ~read:false ~write:false;
  assert (Fake.collect p n = []);
  assert (P.wait p Nowait = 0)

let regular_file () = Fake.with_poller @@ fun p _kernel ->
  let fd = Fake.fd 10 in
  Fake.classify := (fun _ -> `Ready);
  P.set p fd ~read:true ~write:false;
  assert (Fake.collect p (P.wait p Infinite) = [fd, Read_write]);
  assert (Fake.collect p (P.wait p Infinite) = [fd, Read_write])

let cleanup () = Fake.with_poller @@ fun p kernel ->
  P.close p;
  P.close p;
  assert (kernel.closes = 1);
  match P.set p (Fake.fd 10) ~read:true ~write:false with
  | () -> assert false
  | exception Invalid_argument _ -> ()

let failed_close () = Fake.with_poller @@ fun p kernel ->
  let error = Unix.Unix_error (Unix.EIO, "close", "") in
  kernel.fail_close <- Some error;
  begin match P.close p with
  | () -> assert false
  | exception ex -> assert (ex == error)
  end;
  P.close p;
  assert (kernel.closes = 1);
  begin match P.wait p Nowait with
  | _ -> assert false
  | exception Invalid_argument _ -> ()
  end

let probe_error () = Fake.with_poller @@ fun p _kernel ->
  let fd = Fake.fd 10 in
  Fake.classify := (fun _ -> raise (Unix.Unix_error (Unix.EBADF, "fstat", "")));
  P.set p fd ~read:true ~write:false;
  begin match Fake.collect p (P.wait p Nowait) with
  | [got_fd, Error (Unix.Unix_error (Unix.EBADF, "fstat", ""))] -> assert (got_fd = fd)
  | _ -> assert false
  end

let invalid_registration () =
  List.iter (fun code -> Fake.with_poller @@ fun p kernel ->
      let fd = Fake.fd 10 in
      let error = Unix.Unix_error (code, "kevent", "invalid registration") in
      kernel.fail_update <- Some error;
      P.set p fd ~read:true ~write:false;
      assert (Hashtbl.length kernel.registrations = 0);
      assert (Fake.collect p (P.wait p Nowait) = [fd, Error error])
    ) [Unix.EBADF; EINVAL]

let unexpected_update_exception () = Fake.with_poller @@ fun p kernel ->
  let error = Failure "driver bug" in
  kernel.fail_update <- Some error;
  match P.set p (Fake.fd 10) ~read:true ~write:true with
  | () -> failwith "unexpected exception was swallowed"
  | exception ex -> assert (ex == error)

let unexpected_probe_exception () = Fake.with_poller @@ fun p _kernel ->
  let error = Failure "probe bug" in
  Fake.classify := (fun _ -> raise error);
  match P.set p (Fake.fd 10) ~read:true ~write:true with
  | () -> failwith "unexpected exception was swallowed"
  | exception ex -> assert (ex == error)

let first_removal_error () = Fake.with_poller @@ fun p kernel ->
  let first = Unix.Unix_error (Unix.ENOMEM, "kevent", "first") in
  let second = Unix.Unix_error (Unix.EIO, "kevent", "second") in
  List.iteri (fun i error ->
      let fd = Fake.fd (10 + i) in
      P.set p fd ~read:true ~write:false;
      kernel.fail_update <- Some error;
      P.set p fd ~read:false ~write:false
    ) [first; second];
  match P.wait p Nowait with
  | _ -> assert false
  | exception ex -> assert (ex == first)

let interrupted_native_batch () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  P.set p fd ~read:true ~write:true;
  ignore (P.wait p Nowait : int);
  kernel.interrupt <- true;
  begin match P.wait p Infinite with
  | _ -> assert false
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
  end;
  assert (Fake.collect p 0 = []);
  assert (Fake.collect p (P.wait p Nowait) = [fd, Read; fd, Write])

let removal_error () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  P.set p fd ~read:true ~write:false;
  let error = Unix.Unix_error (Unix.ENOMEM, "kevent", "") in
  kernel.fail_update <- Some error;
  P.set p fd ~read:false ~write:false;
  match P.wait p Nowait with
  | _ -> assert false
  | exception ex -> assert (ex = error)

let directional_errors () = Fake.with_poller @@ fun p kernel ->
  let fd = Fake.fd 10 in
  P.set p fd ~read:true ~write:false;
  let token, _, _ = Hashtbl.find kernel.registrations fd in
  let error = Unix.Unix_error (Unix.ECONNRESET, "kevent", "") in
  kernel.next_events <- Some [fd, token, Write_error error; fd, token, Read_error error];
  assert (Fake.collect p (P.wait p Nowait) = [fd, Read_error error])

let () =
  List.iter (fun (name, test) -> test (); Printf.printf "%s: ok\n%!" name) [
    "stale batch and descriptor replacement", stale_batch;
    "keep remaining direction", remaining_direction;
    "partial registration rejection", registration_rejection;
    "partial registration resource error", registration_error;
    "EINTR retains fallback events", interrupted_wait;
    "removed fallback event", removed_pending;
    "regular-file readiness", regular_file;
    "idempotent cleanup", cleanup;
    "failed close is not retried", failed_close;
    "descriptor probe failure", probe_error;
    "invalid registrations are errors, not fallback", invalid_registration;
    "unexpected update exceptions propagate", unexpected_update_exception;
    "unexpected probe exceptions propagate", unexpected_probe_exception;
    "first removal failure is retained", first_removal_error;
    "EINTR does not replay a native batch", interrupted_native_batch;
    "failed removal cannot sleep forever", removal_error;
    "socket errors stay directional", directional_errors;
  ]
