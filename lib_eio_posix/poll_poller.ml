(*
 * Copyright (C) 2023 Thomas Leonard
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Poller_types

module Poll = Iomux.Poll

type t = {
  poll : Poll.t;
  mutable max_index : int;
}

let create () = { poll = Poll.create (); max_index = -1 }

let close _t = ()

let set t fd ~read ~write =
  let index = Iomux.Util.fd_of_unix fd in
  let flags =
    match read, write with
    | false, false -> Poll.Flags.empty
    | true, false -> Poll.Flags.pollin
    | false, true -> Poll.Flags.pollout
    | true, true -> Poll.Flags.(pollin + pollout)
  in
  if flags = Poll.Flags.empty then (
    if index <= t.max_index then (
      Poll.invalidate_index t.poll index;
      (* Find the last populated slot, keeping holes out of the trailing scan. *)
      let rec lower_max_index = function
        | -1 -> t.max_index <- -1
        | i ->
          if Poll.get_fd t.poll i <> Poll.invalid_fd then t.max_index <- i
          else lower_max_index (i - 1)
      in
      if index = t.max_index then lower_max_index (index - 1)
    )
  ) else (
    Poll.set_index t.poll index fd flags;
    if index > t.max_index then t.max_index <- index
  )

let wait t timeout =
  Poll.ppoll_or_poll t.poll (t.max_index + 1) timeout

let iter_ready t nready fn =
  Poll.iter_ready t.poll nready (fun _index fd flags ->
      if Poll.Flags.(mem flags pollnval) then fn fd Unpollable
      else (
        let read = Poll.Flags.(mem flags (pollin + pollhup + pollerr)) in
        let write = Poll.Flags.(mem flags (pollout + pollhup + pollerr)) in
        match read, write with
        | true, false -> fn fd Read
        | false, true -> fn fd Write
        | true, true -> fn fd Read_write
        | false, false -> ()
      )
    )
