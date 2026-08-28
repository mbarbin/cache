(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

let print_stamp s = print_dyn (Cache.Clock.Stamp.to_dyn s)

let%expect_test "Cache.clock: a fresh cache reads Stamp.zero" =
  let cache = Cache.create () in
  require_equal
    (module Cache.Clock.Stamp)
    (Cache.Clock.now (Cache.clock cache))
    Cache.Clock.Stamp.zero;
  ()
;;

let%expect_test "Cache.clock: ticking it directly counts toward a later Var.set's stamp" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  (* Tick the shared clock directly — no [Var.set] involved at all — then
     [set] once. *)
  ignore (Cache.Clock.tick (Cache.clock cache) : Cache.Clock.Stamp.t);
  Cache.Var.set v 2;
  (* [v]'s stamp is the *second* reading, not the first: the manual tick
     was a real write to the one clock [set] itself advances too, not a
     side channel of its own — proof [Cache.clock] hands back the live
     clock every var/node built from [cache] actually shares, not a copy
     or a snapshot. *)
  print_stamp (Cache.Var.stamp v);
  [%expect {| 2 |}];
  ()
;;
