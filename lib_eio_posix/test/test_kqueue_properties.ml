(* Generated state-machine programs are shrunk, including their command lists.
   The model uses registration identities, not the implementation's cookies. *)
module Fake = Kqueue_test_support.Fake_kqueue
module P = Fake.Poller
module Real = Eio_posix__Poller
open Eio_posix__Poller_types
open QCheck2

let slots = 4
let show_list show xs = "[" ^ String.concat "; " (List.map show xs) ^ "]"
let tag = function
  | Read -> "read" | Write -> "write" | Read_write -> "read+write"
  | Unpollable -> "unsupported" | Error _ -> "error"
  | Read_error _ -> "read-error" | Write_error _ -> "write-error"

let read mask = mask land 1 <> 0
let write mask = mask land 2 <> 0
let slot fd = Iomux.Util.fd_of_unix fd - 10
let fd slot = Fake.fd (slot + 10)

type mode = Native | Ready | Unsupported | Rejected | Resource_error
let show_mode = function
  | Native -> "native" | Ready -> "ready" | Unsupported -> "unsupported"
  | Rejected -> "rejected" | Resource_error -> "resource-error"

type command = Set of int * int * mode | Wait | Interrupt | Dispatch of int option

let show_command = function
  | Set (slot, mask, mode) -> Printf.sprintf "set(%d,%d,%s)" slot mask (show_mode mode)
  | Wait -> "wait"
  | Interrupt -> "interrupt"
  | Dispatch None -> "dispatch"
  | Dispatch (Some slot) -> Printf.sprintf "dispatch-and-remove(%d)" slot

let weighted choices =
  Gen.oneof (List.concat_map (fun (weight, generator) ->
      List.init weight (fun _ -> generator)) choices)

let bounded_list limit generator =
  let rec take n = function
    | _ when n = 0 -> []
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  (* Gen.list shrinks by removing interior commands as well as whole chunks;
     list_size shrinks only the generated prefix, which retains many no-ops. *)
  Gen.map (take limit) (Gen.list generator)

let commands =
  let open Gen in
  let slot = int_range 0 (slots - 1) in
  let mode = oneof (List.map return [Native; Ready; Unsupported; Rejected; Resource_error]) in
  let command = weighted [
      6, map (fun (slot, mask, mode) -> Set (slot, mask, mode)) (triple slot (int_range 0 3) mode);
      3, return Wait;
      1, return Interrupt;
      2, return (Dispatch None);
      2, map (fun slot -> Dispatch (Some slot)) slot;
    ]
  in
  bounded_list 120 command

type registration = { identity : unit ref; mask : int; mode : mode }

let model_events model =
  Array.to_list (Array.mapi (fun slot -> function
      | None -> []
      | Some r ->
        let event tag = slot, r.identity, tag in
        match r.mode with
        | Ready -> [event "read+write"]
        | Unsupported | Rejected -> [event "unsupported"]
        | Resource_error -> [event "error"]
        | Native ->
          (if read r.mask then [event "read"] else []) @
          (if write r.mask then [event "write"] else [])
    ) model)
  |> List.concat

let run_model program = Fake.with_poller @@ fun p kernel ->
  let model = Array.make slots None in
  let modes = Array.make slots Native in
  Fake.classify := (fun descriptor -> match modes.(slot descriptor) with
      | Native | Rejected | Resource_error -> `Native
      | Ready -> `Ready
      | Unsupported -> `Unsupported);
  let batch = ref [] and batch_size = ref 0 in
  let wait () =
    batch := model_events model;
    batch_size := P.wait p Nowait;
    assert (!batch_size = List.length !batch)
  in
  let dispatch remove =
    let expected = List.filter_map (fun (slot, identity, tag) ->
        match model.(slot) with
        | Some r when r.identity == identity ->
          if remove = Some slot then model.(slot) <- None;
          Some (slot, tag)
        | _ -> None
      ) !batch
    in
    let observed = ref [] in
    P.iter_ready p !batch_size (fun descriptor event ->
        let slot = slot descriptor in
        observed := (slot, tag event) :: !observed;
        if remove = Some slot then P.set p descriptor ~read:false ~write:false
      );
    assert (List.sort compare expected = List.sort compare !observed)
  in
  List.iter (function
      | Set (slot, mask, mode) ->
        modes.(slot) <- mode;
        if mask <> 0 then (
          let code = match mode with Rejected -> Some Unix.EPERM | Resource_error -> Some Unix.ENOMEM | _ -> None in
          kernel.fail_update <- Option.map (fun code -> Unix.Unix_error (code, "kevent", "")) code
        );
        P.set p (fd slot) ~read:(read mask) ~write:(write mask);
        model.(slot) <- if mask = 0 then None else Some { identity = ref (); mask; mode }
      | Wait -> wait ()
      | Dispatch remove -> dispatch remove
      | Interrupt ->
        kernel.interrupt <- true;
        begin match P.wait p Infinite with
        | _ -> assert false
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
        end;
        batch := [];
        batch_size := 0;
        dispatch None
    ) program;
  wait ();
  dispatch None;
  true

type real_command = Interests of int * int | Replace of int | Send of int | Drain of int | Check
let show_real = function
  | Interests (slot, mask) -> Printf.sprintf "interests(%d,%d)" slot mask
  | Replace slot -> Printf.sprintf "replace(%d)" slot
  | Send slot -> Printf.sprintf "send(%d)" slot
  | Drain slot -> Printf.sprintf "drain(%d)" slot
  | Check -> "check"

let real_commands =
  let open Gen in
  let slot = int_range 0 (slots - 1) in
  bounded_list 80 (weighted [
      5, map (fun (slot, mask) -> Interests (slot, mask)) (pair slot (int_range 0 3));
      2, map (fun slot -> Replace slot) slot;
      2, map (fun slot -> Send slot) slot;
      2, map (fun slot -> Drain slot) slot;
      3, return Check;
    ])

type socket = { descriptor : Unix.file_descr; mutable peer : Unix.file_descr }

let socketpair () =
  let descriptor, peer = Unix.(socketpair ~cloexec:true PF_UNIX SOCK_STREAM 0) in
  Unix.set_nonblock descriptor;
  Unix.set_nonblock peer;
  let wrote = Unix.single_write peer (Bytes.of_string "!") 0 1 in
  assert (wrote = 1);
  { descriptor; peer }

let run_real backend program =
  let sockets = Array.init slots (fun _ -> socketpair ()) in
  Fun.protect ~finally:(fun () ->
      Array.iter (fun s -> Unix.close s.descriptor; Unix.close s.peer) sockets
    ) @@ fun () ->
  let p = Real.create ~backend () in
  Fun.protect ~finally:(fun () -> Real.close p) @@ fun () ->
  let model = Array.make slots 0 in
  let buffered = Array.make slots true in
  let set slot =
    Real.set p sockets.(slot).descriptor ~read:(read model.(slot)) ~write:(write model.(slot))
  in
  let check () =
    let observed = Array.make slots 0 in
    let n = Real.wait p Nowait in
    Real.iter_ready p n (fun descriptor event ->
        let index = ref 0 in
        while !index < slots && sockets.(!index).descriptor <> descriptor do incr index done;
        assert (!index < slots);
        let mask = match event with
          | Read -> 1 | Write -> 2 | Read_write -> 3
          | Unpollable -> failwith "live socket filter was rejected as unsupported"
          | Error ex | Read_error ex | Write_error ex ->
            failwith ("live socket error: " ^ Printexc.to_string ex)
        in
        assert (observed.(!index) land mask = 0);
        observed.(!index) <- observed.(!index) lor mask
      );
    let expected = Array.mapi (fun slot mask ->
        mask land (if buffered.(slot) then 3 else 2)) model in
    assert (observed = expected)
  in
  List.iter (function
      | Interests (slot, mask) -> model.(slot) <- mask; set slot
      | Replace slot ->
        let replacement = socketpair () in
        let s = sockets.(slot) in
        Unix.dup2 ~cloexec:true replacement.descriptor s.descriptor;
        Unix.close replacement.descriptor;
        Unix.close s.peer;
        s.peer <- replacement.peer;
        buffered.(slot) <- true;
        (* No prior deregistration: the kernel has removed the old filter. *)
        set slot
      | Send slot ->
        if not buffered.(slot) then (
          let wrote = Unix.single_write sockets.(slot).peer (Bytes.of_string "!") 0 1 in
          assert (wrote = 1);
          buffered.(slot) <- true
        )
      | Drain slot ->
        if buffered.(slot) then (
          let buf = Bytes.create 1 in
          let got = Unix.read sockets.(slot).descriptor buf 0 1 in
          assert (got = 1 && Bytes.get buf 0 = '!');
          buffered.(slot) <- false
        )
      | Check -> check ()
    ) program;
  check ();
  true

let () =
  if not Real.kqueue_available then (
    if Sys.getenv_opt "EIO_POSIX_POLLER" = Some "kqueue" then
      failwith "native kqueue property requested but kqueue is unavailable";
    prerr_endline "kqueue unavailable: native socket property requires a native build"
  );
  let tests = [
    Test.make ~count:1000 ~name:"kqueue registration state machine"
      ~print:(show_list show_command) commands run_model;
    Test.make ~count:500 ~name:"poll socket readiness model"
      ~print:(show_list show_real) real_commands (run_real `Poll);
  ] in
  let tests = if Real.kqueue_available then
      tests @ [Test.make ~count:500 ~name:"kqueue socket readiness model"
                 ~print:(show_list show_real) real_commands (run_real `Kqueue)]
    else tests
  in
  QCheck_base_runner.run_tests_main tests
