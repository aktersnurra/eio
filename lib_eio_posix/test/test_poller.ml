(* Exercise the multiplexer through the public scheduler interface, including
   cases where one descriptor has more than one kind of waiter. *)

open Eio.Std

let with_socketpair fn =
  let a, b = Unix.(socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0) in
  Fun.protect ~finally:(fun () -> Unix.close a; Unix.close b) @@ fun () ->
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  fn a b

let write_byte fd =
  let wrote = Unix.single_write fd (Bytes.of_string "!") 0 1 in
  assert (wrote = 1)

let fill_socket fd =
  let buf = Bytes.make 4096 'x' in
  let rec loop () =
    match Unix.single_write fd buf 0 (Bytes.length buf) with
    | 0 -> failwith "fill_socket: no progress"
    | _ -> loop ()
    | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (EINTR, _, _) -> loop ()
  in
  loop ()

let drain_socket fd =
  let buf = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd buf 0 (Bytes.length buf) with
    | 0 -> failwith "drain_socket: unexpected EOF"
    | _ -> loop ()
    | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
    | exception Unix.Unix_error (EINTR, _, _) -> loop ()
  in
  loop ()

let fork_waiter ~sw await fd =
  let done_, finish = Promise.create () in
  Fiber.fork ~sw (fun () -> await fd; Promise.resolve finish ());
  done_

let fork_cancellable_waiter ~sw await fd =
  let context, publish_context = Promise.create () in
  let cancelled, finish = Promise.create () in
  Fiber.fork ~sw (fun () ->
      begin try
        Eio.Cancel.sub (fun cc ->
            Promise.resolve publish_context cc;
            await fd;
            failwith "waiter became ready before cancellation"
          )
      with Eio.Cancel.Cancelled _ -> ()
      end;
      Promise.resolve finish ()
    );
  Promise.await context, cancelled

let cancel_waiter (cc, cancelled) =
  Eio.Cancel.cancel cc Exit;
  Promise.await cancelled

let cancel_one_direction ~read =
  with_socketpair @@ fun a b ->
  (* Neither reading nor writing [a] is initially possible. *)
  fill_socket a;
  Switch.run @@ fun sw ->
  let await_cancelled, await_remaining =
    if read then Eio_unix.await_readable, Eio_unix.await_writable
    else Eio_unix.await_writable, Eio_unix.await_readable
  in
  let to_cancel = fork_cancellable_waiter ~sw await_cancelled a in
  let remaining = fork_waiter ~sw await_remaining a in
  cancel_waiter to_cancel;
  assert (not (Promise.is_resolved remaining));
  if read then drain_socket b else write_byte b;
  Promise.await remaining

let cancel_one_reader () =
  with_socketpair @@ fun a b ->
  Switch.run @@ fun sw ->
  let to_cancel = fork_cancellable_waiter ~sw Eio_unix.await_readable a in
  let remaining = fork_waiter ~sw Eio_unix.await_readable a in
  cancel_waiter to_cancel;
  assert (not (Promise.is_resolved remaining));
  write_byte b;
  Promise.await remaining

let read_and_write () =
  with_socketpair @@ fun a b ->
  write_byte b;
  Fiber.both
    (fun () -> Eio_unix.await_readable a)
    (fun () -> Eio_unix.await_writable a)

let remove_highest () =
  with_socketpair @@ fun low peer_low ->
  with_socketpair @@ fun high peer_high ->
  Switch.run @@ fun sw ->
  let low_ready = fork_waiter ~sw Eio_unix.await_readable low in
  cancel_waiter (fork_cancellable_waiter ~sw Eio_unix.await_readable high);
  (* Removing the highest slot must preserve lower registrations. *)
  write_byte peer_low;
  Promise.await low_ready;
  (* Growing the poll set again must restore the higher slot. *)
  let high_ready = fork_waiter ~sw Eio_unix.await_readable high in
  write_byte peer_high;
  Promise.await high_ready

let reuse_descriptor () =
  with_socketpair @@ fun a _old_peer ->
  Switch.run @@ fun sw ->
  cancel_waiter (fork_cancellable_waiter ~sw Eio_unix.await_readable a);
  with_socketpair @@ fun replacement peer ->
  (* Replace the underlying socket, keeping exactly the same FD number. *)
  Unix.dup2 ~cloexec:true replacement a;
  let ready = fork_waiter ~sw Eio_unix.await_readable a in
  assert (not (Promise.is_resolved ready));
  write_byte peer;
  Promise.await ready;
  let buf = Bytes.create 1 in
  let got = Unix.read a buf 0 1 in
  assert (got = 1);
  assert (Bytes.get buf 0 = '!')

let eof () =
  with_socketpair @@ fun a b ->
  Switch.run @@ fun sw ->
  let ready = fork_waiter ~sw Eio_unix.await_readable a in
  Unix.shutdown b Unix.SHUTDOWN_SEND;
  Promise.await ready;
  let got = Unix.read a (Bytes.create 1) 0 1 in
  assert (got = 0)

let regular_file_at_eof () =
  let path, channel = Filename.open_temp_file "eio-poller-" ".tmp" in
  close_out channel;
  Fun.protect ~finally:(fun () -> Unix.unlink path) @@ fun () ->
  let fd = Unix.openfile path [Unix.O_RDWR] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) @@ fun () ->
  Fiber.both
    (fun () -> Eio_unix.await_readable fd)
    (fun () -> Eio_unix.await_writable fd);
  let got = Unix.read fd (Bytes.create 1) 0 1 in
  assert (got = 0)

let eof_with_data () =
  with_socketpair @@ fun a b ->
  write_byte b;
  Unix.shutdown b Unix.SHUTDOWN_SEND;
  Eio_unix.await_readable a;
  let buf = Bytes.create 1 in
  let got = Unix.read a buf 0 1 in
  assert (got = 1 && Bytes.get buf 0 = '!');
  Eio_unix.await_readable a;
  let got = Unix.read a buf 0 1 in
  assert (got = 0)

let peer_shutdown () =
  with_socketpair @@ fun a b ->
  fill_socket a;
  Switch.run @@ fun sw ->
  let read_ready = fork_waiter ~sw Eio_unix.await_readable a in
  let write_ready = fork_waiter ~sw Eio_unix.await_writable a in
  Unix.shutdown b Unix.SHUTDOWN_ALL;
  Promise.await read_ready;
  Promise.await write_ready;
  begin match Unix.single_write a (Bytes.of_string "!") 0 1 with
  | _ -> failwith "write to shut down peer unexpectedly succeeded"
  | exception Unix.Unix_error ((Unix.EPIPE | ECONNRESET), _, _) -> ()
  end

let connection_refused () =
  let reserved = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close reserved) @@ fun () ->
  (* Reserve a local port without listening, so a different server cannot
     accidentally make this connection succeed. *)
  Unix.bind reserved (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let address = Unix.getsockname reserved in
  Switch.run @@ fun sw ->
  let socket = Eio_posix.Low_level.socket ~sw Unix.PF_INET Unix.SOCK_STREAM 0 in
  match Eio_posix.Low_level.connect socket address with
  | () -> failwith "connection to a non-listening socket unexpectedly succeeded"
  | exception Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> ()
  | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)), _) -> ()

let () =
  List.iter (fun (name, test) ->
      Printf.printf "%s:%!" name;
      Eio_posix.run (fun env ->
          let timeout = Eio.Time.Timeout.seconds (Eio.Stdenv.mono_clock env) 5.0 in
          Eio.Time.Timeout.run_exn timeout test
        );
      print_endline " ok"
    ) [
    "cancel reader, keep writer", (fun () -> cancel_one_direction ~read:true);
    "cancel writer, keep reader", (fun () -> cancel_one_direction ~read:false);
    "cancel one of two readers", cancel_one_reader;
    "simultaneous read and write", read_and_write;
    "remove highest descriptor", remove_highest;
    "reuse descriptor number", reuse_descriptor;
    "EOF wakes reader", eof;
    "regular file at EOF", regular_file_at_eof;
    "EOF preserves buffered data", eof_with_data;
    "peer shutdown wakes both directions", peer_shutdown;
    "connection refusal is preserved", connection_refused;
  ]
