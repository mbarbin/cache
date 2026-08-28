(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # The mapN family

   `map2`, `map3`, and whichever arities come after them, all decide
   staleness the same way: they fold their components' stamps together
   with one big disjunction --- stale if the first component moved, or
   the second, or the third. Every component is symmetric in that
   expression, and none of them is special.

   Which is exactly what makes the family easy to under-test. A test that
   only ever writes to the *last* component only ever exercises the last
   disjunct as the reason staleness came out true; the earlier ones never
   get to be the one that decides it, and a bug that dropped a component
   from the fold would go unnoticed. A coverage report caught precisely
   that here: `map3` had never been shown invalidated by its first or its
   second component.

   So each test in this chapter writes to every component in turn, on
   its own, to close that gap at every position rather than only the
   last.

   ## Why this is a chapter of its own

   This is the one part of the library where new code is expected to keep
   arriving --- `map4`, `map5`, and on for as many arities as turn out to
   be wanted. The tests are small, repetitive, and near-identical to one
   another, which is precisely what buries more varied tests in noise when
   they share a file. Kept apart, [Node](test__node.md) stays readable and
   this chapter stays a checklist. *)

(* @mdexp

   ## map2

   Two vars, seeded with distinct powers of ten so that the printed sum
   also pins down *which* component a change landed on, not merely that a
   recompute happened. Each is written once, in its own step, with the
   value and the call count checked immediately after; a final check with
   no write in between confirms the node has settled.

   This is the template an added arity follows: *)

let%expect_test "map2: each component independently triggers a recompute" =
  (* @mdexp.code *)
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
  (* @mdexp

     And it settles: reading again with no write in between does not
     re-fire `f`. *)
  (* @mdexp.code *)
  check ~value:22 ~calls:3;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## map3

   The same shape at arity three --- the one the coverage gap was
   actually found in. *)

let%expect_test "map3: each component independently triggers a recompute" =
  (* @mdexp.code *)
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
  (* @mdexp

     Settling, as before: *)
  (* @mdexp.code *)
  check ~value:222 ~calls:4;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Adding an arity

   Adding `mapN` means adding one more block here, on the template of
   `map2` and `map3`: one var per component, each seeded with a distinct
   power of ten, summed by `f`; each component bumped once in its own
   step with a check right after that value and call count each moved by
   exactly one; and a final check, with no further write, that reading
   again recomputes nothing. Then a `##` section saying which arity it
   is. *)
