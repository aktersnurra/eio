type timeout = Iomux.Poll.ppoll_timeout =
  | Infinite
  | Nowait
  | Nanoseconds of int64

type event =
  | Read
  | Write
  | Read_write
  | Unpollable
  | Error of exn
  | Read_error of exn
  | Write_error of exn

external error_of_errno : int -> Unix.error = "caml_eio_posix_error_of_errno"
