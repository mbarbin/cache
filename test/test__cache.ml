(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Cache

   A cache is the context that vars and nodes are created in. It holds
   the logical clock they all share, and little else. Creating one is
   cheap, and two caches never interact: an operation spanning both is
   an error rather than something the library reconciles.

   `Cache.Private.clock` exposes that clock. It is not part of the API:
   a caller never has to consult it, and the two stamp accessors that
   would give a reading meaning live behind `Private` too. The tests
   need them, to observe when something moved. *)

let print_stamp s = print_dyn (Cache.Private.Clock.Stamp.to_dyn s)

(* @mdexp

   ## A fresh cache reads zero

   Nothing has been written, so the clock is at `Stamp.zero`. Every
   stamp in the library is a reading of this one clock, which makes
   "zero" mean "no write has happened yet" rather than "no write to this
   particular thing". *)

let%expect_test "Cache.clock: a fresh cache reads Stamp.zero" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.Clock.settle (Cache.Private.clock cache))
    Cache.Private.Clock.Stamp.zero;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## The clock handed back is the live one

   `Cache.Private.clock` returns the clock `Var.set` itself announces
   writes on, not a copy or a snapshot of it. Take a reading by hand,
   with no `Var.set` involved anywhere --- `reserve` to reserve one,
   `settle` to settle onto it the way a recomputing node does: *)

let%expect_test "Cache.clock: a reading taken by hand counts toward a later Var.set" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let clock = Cache.Private.clock cache in
  let v = Cache.Var.create cache 1 in
  ignore (Cache.Private.Clock.reserve clock : Cache.Private.Clock.Stamp.t);
  ignore (Cache.Private.Clock.settle clock : Cache.Private.Clock.Stamp.t);
  (* @mdexp

     Then write the var once. Its stamp comes out as the *second*
     reading, not the first: the reading taken by hand was taken off the
     one clock `set` announces on too. Had `clock` handed back a side
     channel of its own, this would print 1. *)
  (* @mdexp.code *)
  Cache.Var.set v 2;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 2 |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## One reading per run of writes

   The clock a cache holds does not hand out a reading per write; it
   hands out one per *phase* of writes. That is a property of the clock
   rather than of the cache, and [Clock](test__clock.md) is where it is
   set out and pinned. *)
