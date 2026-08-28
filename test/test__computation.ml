(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

let%expect_test "Computation: lazy, only refires after invalidate, not at invalidate time"
  =
  let cache = Cache.create () in
  let source = ref 1 in
  let calls = ref 0 in
  let computed =
    Cache.Computation.create cache ~f:(fun () ->
      incr calls;
      !source)
  in
  let check ~value ~calls:expected_calls =
    require_equal (module Int) (Cache.Node.value (Cache.Computation.node computed)) value;
    require_equal (module Int) !calls expected_calls
  in
  check ~value:1 ~calls:1;
  (* Reading again without invalidating doesn't recompute. *)
  check ~value:1 ~calls:1;
  (* The source changes twice, but [invalidate] doesn't itself call
     [f] — only the next read does, once, seeing the latest value. *)
  source := 2;
  Cache.Computation.invalidate computed;
  source := 3;
  Cache.Computation.invalidate computed;
  require_equal (module Int) !calls 1;
  check ~value:3 ~calls:2;
  ()
;;

let%expect_test "Computation: a downstream node sees the change too, once" =
  let cache = Cache.create () in
  let source = ref 1 in
  let computed = Cache.Computation.create cache ~f:(fun () -> !source) in
  let downstream_calls = ref 0 in
  let downstream =
    Cache.Node.map (Cache.Computation.node computed) ~f:(fun x ->
      incr downstream_calls;
      x * 10)
  in
  let check ~value ~calls =
    require_equal (module Int) (Cache.Node.value downstream) value;
    require_equal (module Int) !downstream_calls calls
  in
  check ~value:10 ~calls:1;
  source := 2;
  Cache.Computation.invalidate computed;
  check ~value:20 ~calls:2;
  ()
;;

let%expect_test "invalidate raises when called from inside a node's computation" =
  let cache = Cache.create () in
  let source = ref 0 in
  let comp = Cache.Computation.create cache ~f:(fun () -> !source) in
  let v = Cache.Var.create cache 1 in
  let node =
    Cache.Node.map (Cache.Var.watch v) ~f:(fun (_ : int) ->
      Cache.Computation.invalidate comp)
  in
  require_does_raise (fun () : unit -> Cache.Node.value node);
  [%expect
    {|
    Invalid_argument("Cache.Computation.invalidate: a computation cannot be invalidated while a node is being computed")
    |}];
  (* Invalidating from outside is unaffected. *)
  incr source;
  Cache.Computation.invalidate comp;
  require_equal (module Int) (Cache.Node.value (Cache.Computation.node comp)) 1;
  ()
;;
