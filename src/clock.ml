(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

module Stamp = struct
  type t = int

  let zero = 0
  let equal = Int.equal
  let ( > ) = Stdlib.( > )
  let to_dyn = Dyn.int

  (* Not exposed in the [.mli]: only [Clock.tick] gets to mint the next
     reading. *)
  let next t = t + 1
end

type t = { mutable current : Stamp.t }

let create () = { current = Stamp.zero }
let now t = t.current

let tick t =
  t.current <- Stamp.next t.current;
  t.current
;;
