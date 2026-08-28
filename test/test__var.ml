(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

let print_stamp s = print_dyn (Cache.Clock.Stamp.to_dyn s)

let%expect_test "create starts at Stamp.zero" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  require_equal (module Int) (Cache.Var.peek v) 1;
  require_equal (module Cache.Clock.Stamp) (Cache.Var.stamp v) Cache.Clock.Stamp.zero;
  ()
;;

let%expect_test "create starts at Stamp.zero even after the cache has ticked" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  Cache.Var.set a "a1";
  (* [cache] is now at reading 1. A var created afterwards still starts
     at [Stamp.zero], not "the cache's current reading" — [create]
     doesn't read the cache at all, only [set] does. *)
  let b = Cache.Var.create cache "b0" in
  require_equal (module Cache.Clock.Stamp) (Cache.Var.stamp b) Cache.Clock.Stamp.zero;
  ()
;;

let%expect_test "set replaces the value and ticks the shared cache" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Var.peek v) 2;
  print_stamp (Cache.Var.stamp v);
  [%expect {| 1 |}];
  Cache.Var.set v 3;
  require_equal (module Int) (Cache.Var.peek v) 3;
  print_stamp (Cache.Var.stamp v);
  [%expect {| 2 |}];
  ()
;;

let%expect_test "two vars sharing a cache: only the one written ticks" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  let b = Cache.Var.create cache "b0" in
  Cache.Var.set a "a1";
  print_stamp (Cache.Var.stamp a);
  [%expect {| 1 |}];
  (* [b] keeps its own stamp even though the shared cache moved on. *)
  require_equal (module Cache.Clock.Stamp) (Cache.Var.stamp b) Cache.Clock.Stamp.zero;
  require_equal (module String) (Cache.Var.peek b) "b0";
  ()
;;

let%expect_test "set raises when called from inside a node's computation" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let other = Cache.Var.create cache 10 in
  let node =
    (* The cascade this would start is exactly the one that would be
       swallowed by this very node, mid-refresh — refused instead. *)
    Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> Cache.Var.set other (x * 2))
  in
  require_does_raise (fun () : unit -> Cache.Node.value node);
  [%expect
    {|
    Invalid_argument("Cache.Var.set: a var cannot be set while a node is being computed")
    |}];
  (* The failed refresh doesn't leave the cache wedged: writes from
     outside still work, and the node still recomputes (and raises
     again, [f] being unchanged). *)
  Cache.Var.set other 20;
  require_equal (module Int) (Cache.Var.peek other) 20;
  ()
;;

let%expect_test "reading a node from inside a computation: allowed, but untracked" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let w = Cache.Var.create cache 100 in
  let inner = Cache.Node.map (Cache.Var.watch w) ~f:(fun x -> x + 1) in
  let outer =
    Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
      (* A nested pull, not a write: nothing is told anything, so unlike
         [Var.set] above this doesn't raise. *)
      x + Cache.Node.value inner)
  in
  require_equal (module Int) (Cache.Node.value outer) 102;
  (* The flag was released on the way out — writing still works. *)
  Cache.Var.set w 200;
  (* But [outer] was built from [v] alone: reading [inner] inside [f]
     is exactly as untracked a dependency as [Var.peek] would be, so
     [outer] is not stale here and keeps its value. Nothing about the
     graph is broken — [outer] simply never depended on [w]. Building
     [outer] with [map2] over [inner] is what makes that a dependency. *)
  require_equal (module Int) (Cache.Node.value outer) 102;
  (* A write to what [outer] *does* depend on picks up the new [inner]. *)
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Node.value outer) 203;
  ()
;;
