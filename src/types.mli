(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

open! Import

(*_ Not an abstraction boundary — see [types.ml]'s header. Every field
  below is manifest (not hidden), on purpose: this exists so [var.ml] and
  [node.ml] can share one representation, not to expose one to the other
  through an API — ['a computation] at the bottom is the one-directional
  case of that same idea, [computation.ml] needing [node] rather than the
  two needing each other. [cache.mli] is the library's real boundary and
  never mentions this module. *)

(*_ [Collect]'s key needs all four: [equal]/[hash] to build and probe
  [table] (a [Hashtbl.t], read [node.ml]'s own doc for why that stays a
  Hashtbl rather than moving to the comparator-based [Set.t]/[Map.t]
  used for [keys]/the result), and [compare]/[comparator_witness] to
  mint the [Set.t] values [Collect] reads and the very first, empty
  result [Map.t] via {!Map.empty} on a [Collect] node's first
  [refresh] (when [cached] is still [None] — every [refresh] after
  that folds onto the previous result instead). *)
module type Key = sig
  type t
  type comparator_witness

  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> Ordering.t
end

type cache =
  { clock : Clock.t
  ; mutable refreshing : bool
  }

[@@@warning "-30"]

type 'a var =
  { cache : cache
  ; mutable value : 'a
  ; mutable stamp : Clock.Stamp.t
  ; mutable children : packed list
  }

and 'a node =
  { cache : cache
  ; mutable is_invalidated : bool
  ; mutable stamp : Clock.Stamp.t
  ; mutable checked_at : Clock.Stamp.t
  ; mutable cached : 'a option
  ; mutable equal : 'a -> 'a -> bool
  ; mutable children : packed list
  ; shape : 'a shape
  }

and packed = Packed : 'a node -> packed [@@unboxed]

and _ shape =
  | Const : 'a -> 'a shape
  | Var : 'a var -> 'a shape
  | Collect :
      { key_module : (module Key with type t = 'k and type comparator_witness = 'cmp)
      ; keys : ('k, 'cmp) Set.t node
      ; f : 'k -> 'v node
      ; table : ('k, 'v node) Hashtbl.t
      }
      -> ('k, 'v, 'cmp) Map.t shape
  | Computation : (unit -> 'a) -> 'a shape
  | Map :
      { a : 'p node
      ; f : 'p -> 'a
      }
      -> 'a shape
  | Map2 :
      { a : 'p1 node
      ; b : 'p2 node
      ; f : 'p1 -> 'p2 -> 'a
      }
      -> 'a shape
  | Map3 :
      { a : 'p1 node
      ; b : 'p2 node
      ; c : 'p3 node
      ; f : 'p1 -> 'p2 -> 'p3 -> 'a
      }
      -> 'a shape

type 'a computation =
  { node : 'a node
  ; invalidate : unit -> unit
  }
