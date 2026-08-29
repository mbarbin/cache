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

   Creating a var is not a write. It reserves no reading, and the
   var starts at `Stamp.zero` --- the reading that means "never
   written". *)

let%expect_test "create starts at Stamp.zero" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  require_equal (module Int) (Cache.Var.peek v) 1;
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp v)
    Cache.Private.Clock.Stamp.zero;
  (* @mdexp.end *)
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

let%expect_test "create starts at Stamp.zero even after the cache has moved on" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  Cache.Var.set a "a1";
  (* @mdexp

     `cache` is announcing writes at reading 1 now. A var created at
     this point still starts at zero: *)
  (* @mdexp.code *)
  let b = Cache.Var.create cache "b0" in
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp b)
    Cache.Private.Clock.Stamp.zero;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## set

   `set` replaces the value and stamps the var with the reading the
   shared clock is currently announcing writes by. A second write with
   nothing pulled in between belongs to the same run and carries the
   same reading --- no node looked between the two, so nothing is in a
   position to tell them apart. See
   [Clock](test__clock.md#next-reserves-one-reading-for-a-whole-phase). *)

let%expect_test "set replaces the value and stamps the var" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Var.peek v) 2;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 1 |}];
  Cache.Var.set v 3;
  require_equal (module Int) (Cache.Var.peek v) 3;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 1 |}];
  (* @mdexp

     Pulling a node built on the var is what closes that reading off: the
     node stamps itself with it, and from then on it is a reading
     something has been compared against. The write after that starts a
     run of its own, and is announced by a reading of its own: *)
  (* @mdexp.code *)
  let n = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 10) in
  require_equal (module Int) (Cache.Node.value n) 30;
  Cache.Var.set v 4;
  print_stamp (Cache.Private.var_stamp v);
  [%expect {| 2 |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   The clock is shared; the stamps are not. Writing one var moves the
   clock on, which every var in the cache can see, but leaves every
   other var's own stamp exactly where it was. That is what lets a node compare
   its parent's stamp against its own last look and conclude nothing
   relevant happened, even though the cache as a whole has moved on. *)

let%expect_test "two vars sharing a cache: only the one written is stamped" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let a = Cache.Var.create cache "a0" in
  let b = Cache.Var.create cache "b0" in
  Cache.Var.set a "a1";
  print_stamp (Cache.Private.var_stamp a);
  [%expect {| 1 |}];
  (* @mdexp

     `b` keeps its own stamp, and its own value, even though the clock it
     shares with `a` has moved on: *)
  (* @mdexp.code *)
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.var_stamp b)
    Cache.Private.Clock.Stamp.zero;
  require_equal (module String) (Cache.Var.peek b) "b0";
  (* @mdexp.end *)
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
   the next time it is read (raising again, `f` being unchanged).

   A node whose `f` writes another var, forced: *)

let%expect_test "set raises when called from inside a node's computation" =
  (* @mdexp.code *)
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
  (* @mdexp

     The failed refresh leaves nothing wedged. A write from outside still
     works: *)
  (* @mdexp.code *)
  Cache.Var.set other 20;
  require_equal (module Int) (Cache.Var.peek other) 20;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ### From a computation's own `f`

   A `Computation.create` closure is no exception. The guard covers the
   whole of a `Node.value` call, whatever kind of node that call runs, so
   a `set` from a computation's own `f` is refused exactly as one from a
   `map`'s is.

   The var written below is one the computation does not read, and has no
   node watching it at all. It is still refused: the check is on a refresh
   being in flight, not on who the cascade would have reached: *)

let%expect_test "set raises when called from a computation's own f" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let other = Cache.Var.create cache 10 in
  let comp = Cache.Computation.create cache ~f:(fun () -> Cache.Var.set other 20) in
  require_does_raise (fun () : unit -> Cache.Node.value (Cache.Computation.node comp));
  [%expect
    {|
    Invalid_argument("Cache.Var.set: a var cannot be set while a node is being computed")
    |}];
  (* @mdexp

     And refused before anything is mutated, not rolled back after the
     fact --- `other` still holds what it held: *)
  (* @mdexp.code *)
  require_equal (module Int) (Cache.Var.peek other) 10;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   Reading, by contrast, is allowed from inside a computation and does
   not raise --- but records no dependency either, which is a trap of a
   different kind. That is a story spanning `Var`, `Node` and
   `Computation` rather than a fact about `set`, and it has a chapter of
   its own: [Invalid uses](invalid_uses.md). *)
