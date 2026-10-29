(* Test-only fixture: no dependency on a controlling terminal or interactive CI. *)
external open_pair : unit -> Unix.file_descr * Unix.file_descr = "caml_eio_test_open_pty"
