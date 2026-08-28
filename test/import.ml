(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

let phys_equal : 'a -> 'a -> bool = Stdlib.( == )

module List = struct
  include ListLabels
end

module String = struct
  include StringLabels

  let to_dyn = Dyn.string
end

module Int = struct
  include Int

  let to_dyn = Dyn.int
end

module Bool = struct
  include Bool

  let to_dyn = Dyn.bool
end

let print_dyn dyn = print_endline (Dyn.to_string dyn)

let require_does_raise f =
  match f () with
  | _ -> failwith "Did not raise."
  | exception e -> print_endline (Printexc.to_string e)
;;

module type With_equal_and_dyn = sig
  type t

  val equal : t -> t -> bool
  val to_dyn : t -> Dyn.t
end

let require_equal
      (type a)
      (module M : With_equal_and_dyn with type t = a)
      (actual : a)
      (expected : a)
  =
  if not (M.equal actual expected)
  then (
    print_dyn (Dyn.record [ "actual", M.to_dyn actual; "expected", M.to_dyn expected ]);
    failwith "Values are not equal.")
;;
