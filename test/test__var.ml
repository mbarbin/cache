(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Var

   A var is the mutable leaf everything else is ultimately derived from.
   It holds a value, remembers the clock reading of its last write, and
   knows which nodes are watching it right now.

   Reading one with `Var.peek` records nothing: it is a plain field
   access, and the reader does not become dependent on the var. Depending
   on a var means watching it --- see [Node](test__node.md). *)

let print_stamp s = print_dyn (Cache.Private.Clock.Stamp.to_dyn s)

(* @mdexp

   ## create

   Creating a var is not a write. It does not advance the clock, and the
   var starts at `Stamp.zero` --- the reading that means "never
   written". *)

let%expect_test "create starts at Stamp.zero" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  require_equal (module Int) (Cache.Var.peek v) 1;
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp v)
    Cache.Private.Clock.Stamp.zero;
  ()
;;

(* @mdexp

   That holds however busy the cache already is. A var created long after
   other vars have been written still starts at zero, rather than at the
   clock's current reading: `create` never looks at the clock, only `set`
   does.

   Nothing about recomputation depends on that. A watch node learns its
   var moved by being *told* --- `set` walks the var's watchers and marks
   them --- and `refresh` never reads a var's stamp at all. What the zero
   buys is an answer to a question someone can ask: the stamp is zero
   exactly when the var has never been written, where stamping "now" at
   creation would leave never-written and written-on-creation
   indistinguishable. *)

let%expect_test "create starts at Stamp.zero even after the cache has ticked" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  Cache.Var.set a "a1";
  (* [cache] is now at reading 1. A var created afterwards still starts
     at [Stamp.zero], not "the cache's current reading" — [create]
     doesn't read the cache at all, only [set] does. *)
  let b = Cache.Var.create cache "b0" in
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp b)
    Cache.Private.Clock.Stamp.zero;
  ()
;;

(* @mdexp

   ## set

   `set` replaces the value and advances the shared clock by one; that
   new reading becomes the var's stamp. Two writes, two readings: 1 then
   2. *)

let%expect_test "set replaces the value and ticks the shared cache" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Var.peek v) 2;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 1 |}];
  Cache.Var.set v 3;
  require_equal (module Int) (Cache.Var.peek v) 3;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 2 |}];
  ()
;;

(* @mdexp

   The clock is shared; the stamps are not. Writing one var moves the
   clock, which every var in the cache can see, but leaves every other
   var's own stamp exactly where it was. That is what lets a node compare
   its parent's stamp against its own last look and conclude nothing
   relevant happened, even though the cache as a whole has moved on. *)

let%expect_test "two vars sharing a cache: only the one written ticks" =
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  let b = Cache.Var.create cache "b0" in
  Cache.Var.set a "a1";
  print_stamp (Cache.Private.var_stamp a);
  [%expect {| 1 |}];
  (* [b] keeps its own stamp even though the shared cache moved on. *)
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp b)
    Cache.Private.Clock.Stamp.zero;
  require_equal (module String) (Cache.Var.peek b) "b0";
  ()
;;

(* @mdexp

   ## Writing from inside a computation is refused

   A node's `f` must not write a var. The write would invalidate whatever
   is watching that var --- possibly including the very node that is
   part-way through its own refresh --- and the update would be dropped
   silently, leaving a node holding a value it should have recomputed.

   Rather than let that happen quietly, `set` raises `Invalid_argument`
   when a computation is in progress. The failed refresh leaves nothing
   wedged: writes from outside work as before, and the node recomputes
   the next time it is read (raising again, `f` being unchanged). *)

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

(* @mdexp

   ## Reading a node from inside a computation is allowed

   A nested read tells nothing to anybody, so unlike a write it does not
   raise. It also records nothing: the outer node does not become
   dependent on what it read, exactly as `Var.peek` would not make it
   dependent on a var. It will not be recomputed when that value changes,
   and will happily go on serving the answer it computed from it.

   This is worth stating because the read *works*, and gives the right
   answer at the time. Nothing is broken --- the dependency simply was
   never declared. Building the node with `map2` over both parents is
   what declares it. *)

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
