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

  (* Everything [Cache.Node.collect] asks of a key type, answered here
     rather than by a key module each chapter defines for itself: [hash]
     for the [Hashtbl.t] [collect] memoizes children in, and [compare]
     plus [comparator_witness] for the [Set.t] of keys it reads and the
     [Map.t] it returns. [Stdlib.Int]'s own [int]-returning [compare] is
     shadowed rather than kept alongside — the key signature calls for an
     [Ordering.t], and no test wants the other one. With [equal] (from
     [Stdlib.Int]) and [to_dyn] below, one module then answers for every
     role a test needs of an integer: {!require_equal}, the hash table,
     the key set, and [collect] itself. *)
  type comparator_witness

  let hash = Stdlib.Hashtbl.hash
  let compare a b = Ordering.of_int (Stdlib.Int.compare a b)
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
