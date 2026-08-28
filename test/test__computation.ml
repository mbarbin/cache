(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Computation

   A computation is a node with no var and no node above it. It caches
   the result of an `f` that reads state this library cannot see into ---
   a file's parsed contents, the answer to a query --- and is marked
   stale by an explicit `Computation.invalidate` call rather than by a
   write.

   It is the escape hatch for leaves that change for reasons the graph
   has no way to observe. Everything downstream of it then behaves like
   any other part of the graph.

   ## invalidate marks; the next read recomputes

   `invalidate` does not call `f`. It marks the node stale and returns,
   leaving the recompute to whoever reads next --- which is the same
   discipline `Var.set` follows, and for the same reason: the library
   only ever computes what someone asked for.

   Two consequences, and the test pins both: invalidating twice between
   reads costs one recompute rather than two, and the value `f` finally
   returns is the one the state held at *read* time, not the one it held
   at either `invalidate`. *)

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

(* @mdexp

   ## Nodes built on top see the change

   `Computation.node` gives the node to compose with, and from there
   nothing is special: an invalidated computation makes what was built on
   it stale, and a read pulls the change through --- once. *)

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

(* @mdexp

   ## Invalidating from inside a computation is refused

   The same restriction that applies to `Var.set` applies here, for the
   same reason: an invalidation issued from inside a running computation
   would be lost. It raises `Invalid_argument`, and invalidating from
   outside is unaffected afterwards. See
   [Var](test__var.md#writing-from-inside-a-computation-is-refused). *)

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
