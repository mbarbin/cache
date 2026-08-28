(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import
open Types

type 'a t = 'a var

let create cache value : 'a t = { cache; value; stamp = Clock.Stamp.zero; children = [] }
let peek (t : 'a t) = t.value

let set (t : 'a t) value =
  (* Before anything is mutated: a write issued from inside a node's own
     computation is refused outright, rather than cascading into a
     watcher that is part-way through its own refresh and losing the
     update there (see [types.ml]'s [refreshing]). *)
  Node.Private.assert_not_refreshing_exn
    t.cache
    ~msg:"Cache.Var.set: a var cannot be set while a node is being computed";
  t.value <- value;
  t.stamp <- Clock.tick t.cache.clock;
  (* Every currently-connected watcher gets told, unconditionally — [Var]
     has no cutoff of its own (unlike [Node.t], every [set] counts, even
     to the same value; it's the watching node's own default-[phys_equal]
     cutoff that then decides whether that propagates any further, see
     the "unit Var used as a pure signal" test). Taking the list out and
     clearing [t.children] first, rather than iterating it in place, is
     what disconnects every one of them in the same move: each entry is
     about to be marked invalidated, and a node only ever belongs in here
     while resolved, so there is nothing to preserve. *)
  let children = t.children in
  t.children <- [];
  List.iter children ~f:(fun (Packed node) -> Node.Private.invalidate node)
;;

let stamp (t : _ t) = t.stamp
