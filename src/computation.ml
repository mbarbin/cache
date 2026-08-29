(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import
open Types

type 'a t = 'a computation

let create cache ~(f : unit -> 'a) : 'a t =
  let node = Node.Private.computation ~cache ~f in
  let invalidate () =
    (* Same reentrancy guard as {!Var.set}, for the same reason: told from
       inside a node's own computation, this cascade would be swallowed
       by whichever node is mid-refresh (see [types.ml]'s [refreshing]). *)
    Node.Private.assert_not_refreshing_exn
      cache
      ~msg:
        "Cache.Computation.invalidate: a computation cannot be invalidated while a node \
         is being computed";
    (* Reserving the next reading is what makes the recompute to come
       visible downstream. A computation has no parent whose stamp could
       move, so when its node re-runs [f] it stamps itself with whatever
       [Clock.settle] settles on at that moment. Without this, and with
       nothing else having written meanwhile, that reading is the very
       one a child already recorded in its own [checked_at] — so the
       child would compare the two, find nothing greater, and absorb a
       change that really did happen.

       The reservation is shared with every other write up to the next
       recompute: invalidating twice over, or invalidating alongside a
       {!Var.set}, costs one reading between them rather than one
       apiece (see [clock.ml]). *)
    ignore (Clock.reserve cache.clock : Clock.Stamp.t);
    Node.Private.invalidate node
  in
  { node; invalidate }
;;

let node (t : 'a t) = t.node
let invalidate (t : 'a t) = t.invalidate ()
