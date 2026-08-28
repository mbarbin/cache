(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* [map2]/[map3]/... each fold their arity's stamps together with one big
   [||] (see [node.ml]'s [refresh]) — [stamp_a > checked_at || stamp_b > checked_at || ...] — and a test that only ever moves the *last*
   component only ever exercises that last disjunct as the reason
   [stale] came out [true]; the earlier ones never get to be the one
   that decides it. A coverage report caught exactly that: [map3]
   never shown invalidated by its first or second component. Every test
   below sets each component in turn, on its own, specifically to close
   that gap for every position, not just the last one.

   Kept in its own file, one [%expect_test] per arity, rather than folded
   into [test__node.ml]: this is the one part of the library where a new
   arity is expected to keep showing up ([map4], [map5], and on for as
   many as turn out to be wanted) — small, repetitive, and otherwise
   exactly the kind of thing
   that buries the more varied tests living alongside it in noise. Adding
   [mapN] means adding one more block here, following the same template
   as [map2]/[map3] below: one var per component, seeded with a distinct
   power of ten (so the printed value also pins down *which* component a
   change landed on, not just that recompute happened), summed by [f],
   each component bumped once in its own step with a [print] right after
   to check [value]/[calls] moved by exactly one, and a final [print]
   with no further write to confirm settling. *)

let%expect_test "map2: each component independently triggers a recompute" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache 1 in
  let b = Cache.Var.create cache 10 in
  let calls = ref 0 in
  let n =
    Cache.Node.map2 (Cache.Var.watch a) (Cache.Var.watch b) ~f:(fun a b ->
      incr calls;
      a + b)
  in
  let check ~value ~calls:expected_calls =
    require_equal (module Int) (Cache.Node.value n) value;
    require_equal (module Int) !calls expected_calls
  in
  check ~value:11 ~calls:1;
  Cache.Var.set a 2;
  check ~value:12 ~calls:2;
  Cache.Var.set b 20;
  check ~value:22 ~calls:3;
  (* Re-reading without a further write doesn't re-fire [f]. *)
  check ~value:22 ~calls:3;
  ()
;;

let%expect_test "map3: each component independently triggers a recompute" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache 1 in
  let b = Cache.Var.create cache 10 in
  let c = Cache.Var.create cache 100 in
  let calls = ref 0 in
  let n =
    Cache.Node.map3
      (Cache.Var.watch a)
      (Cache.Var.watch b)
      (Cache.Var.watch c)
      ~f:(fun a b c ->
        incr calls;
        a + b + c)
  in
  let check ~value ~calls:expected_calls =
    require_equal (module Int) (Cache.Node.value n) value;
    require_equal (module Int) !calls expected_calls
  in
  check ~value:111 ~calls:1;
  Cache.Var.set a 2;
  check ~value:112 ~calls:2;
  Cache.Var.set b 20;
  check ~value:122 ~calls:3;
  Cache.Var.set c 200;
  check ~value:222 ~calls:4;
  (* Re-reading without a further write doesn't re-fire [f]. *)
  check ~value:222 ~calls:4;
  ()
;;
