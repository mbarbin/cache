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
  let cache = Cache.create () in
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.Clock.now (Cache.Private.clock cache))
    Cache.Private.Clock.Stamp.zero;
  ()
;;

(* @mdexp

   ## The clock handed back is the live one

   `Cache.clock` returns the clock that `Var.set` itself advances, not a
   copy or a snapshot of it. Ticking it by hand and then writing a var
   makes that visible: the var's stamp comes out as the *second*
   reading, because the manual tick already consumed the first. Had
   `clock` returned a side channel of its own, the write would have
   stamped the var with 1. *)

let%expect_test "Cache.clock: ticking it directly counts toward a later Var.set's stamp" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  (* Tick the shared clock directly — no [Var.set] involved at all — then
     [set] once. *)
  ignore
    (Cache.Private.Clock.tick (Cache.Private.clock cache) : Cache.Private.Clock.Stamp.t);
  Cache.Var.set v 2;
  (* [v]'s stamp is the *second* reading, not the first: the manual tick
     was a real write to the one clock [set] itself advances too, not a
     side channel of its own — proof [Cache.clock] hands back the live
     clock every var/node built from [cache] actually shares, not a copy
     or a snapshot. *)
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 2 |}];
  ()
;;
