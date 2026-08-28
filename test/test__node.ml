(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Node

   A node is a memoized computation over vars and over other nodes. It
   remembers the value it last produced, the clock reading at which that
   value last changed, and the reading at which it last checked ---
   which, compared against its parents' readings, is what lets it decide
   it has nothing to do.

   Nothing here computes on a schedule. A node runs when someone reads
   it and its parents have moved since it last looked; a node nobody
   reads never runs at all.

   ## watch

   `Var.watch` is where a graph starts: a node whose value is a var's
   current value. Writing the var and reading the node again yields the
   new value. *)

let%expect_test "watch reflects the var's current value" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let n = Cache.Var.watch v in
  require_equal (module Int) (Cache.Node.value n) 1;
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Node.value n) 2;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## A unit var used as a signal

   A watch node carries the default `phys_equal` cutoff like any other,
   and that has a consequence worth knowing before it surprises someone:
   a var whose type has essentially one value never *looks* changed. A
   `unit Var.t` used as a "something happened" signal is the case in
   point --- `()` is physically equal to itself, so every write is
   absorbed and nothing downstream ever fires.

   Note which node the cutoff has to be disabled on: `watch` builds a
   fresh node per call, so the node passed to `map` is the one that must
   be kept and set, not a second `watch` of the same var. *)

let%expect_test "a unit Var used as a pure signal needs its cutoff disabled" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let signal = Cache.Var.create cache () in
  (* [watch] builds a fresh node each call, so this one has to be kept and
     reused below rather than calling [watch] again — otherwise disabling
     cutoff on a second, independent node wouldn't touch this one. *)
  let signal_node = Cache.Var.watch signal in
  let calls = ref 0 in
  let n =
    Cache.Node.map signal_node ~f:(fun () ->
      incr calls;
      !calls)
  in
  require_equal (module Int) (Cache.Node.value n) 1;
  (* @mdexp.end *)
  (* @mdexp

     `()` is `phys_equal` to itself, always, so the default cutoff on the
     watch node swallows this write and `n` never recomputes: *)
  (* @mdexp.code *)
  Cache.Var.set signal ();
  require_equal (module Int) (Cache.Node.value n) 1;
  (* @mdexp.end *)
  (* @mdexp

     Disabling that cutoff makes every write count: *)
  (* @mdexp.code *)
  Cache.Node.set_cutoff signal_node ~equal:(fun () () -> false);
  Cache.Var.set signal ();
  require_equal (module Int) (Cache.Node.value n) 2;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## map

   `map` runs `f` on demand, and only when its parent has actually moved.
   Reading twice with no write in between runs `f` once.

   This is the shape most of the tests in this book take: a counter
   incremented inside `f`, and a check that pins the value and the number
   of times `f` has run together, so that "it did not recompute" is
   asserted rather than assumed. *)

let%expect_test "map only recomputes when the parent's stamp moved" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let calls = ref 0 in
  let n =
    Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
      incr calls;
      x * 10)
  in
  let check ~value ~calls:expected_calls =
    require_equal (module Int) (Cache.Node.value n) value;
    require_equal (module Int) !calls expected_calls
  in
  check ~value:10 ~calls:1;
  check ~value:10 ~calls:1;
  Cache.Var.set v 2;
  check ~value:20 ~calls:2;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   Writes are targeted rather than global: a write to some other var in
   the same cache advances the shared clock, but does not make this node
   stale. Staleness is decided against the parents a node actually has,
   not against the clock. *)

let%expect_test "an unrelated var's write doesn't force a recompute" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let unrelated = Cache.Var.create cache "x" in
  let calls = ref 0 in
  let n =
    Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
      incr calls;
      x * 10)
  in
  ignore (Cache.Node.value n : int);
  Cache.Var.set unrelated "y";
  require_equal (module Int) (Cache.Node.value n) 10;
  require_equal (module Int) !calls 1;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   `map2`, `map3` and the rest of the family get systematic,
   per-component coverage of their own rather than one case each here:
   see [The mapN family](test__mapn.md). *)

(* @mdexp

   ## Cutoff

   A cutoff decides when a recompute counts as a *change*. When the value
   a node has just produced is `equal` to the one it was already holding,
   its stamp stays put and nothing built on it recomputes --- the node
   itself still ran, since running is how it found out.

   That distinction is the whole point: work is stopped at the first node
   where the value stopped moving, rather than at the first node where
   the inputs stopped moving. Below, a node reduces an integer to its
   parity --- many different integers share one --- and a downstream node
   counts how often it runs: *)

let%expect_test "cutoff stops a downstream recompute when the value didn't really change" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 5 in
  (* Many different [v] map to the same parity: [set_cutoff Int.equal]
     lets [mid] absorb those. *)
  let mid = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x mod 2) in
  Cache.Node.set_cutoff mid ~equal:Int.equal;
  let downstream_calls = ref 0 in
  let downstream =
    Cache.Node.map mid ~f:(fun parity ->
      incr downstream_calls;
      parity)
  in
  ignore (Cache.Node.value downstream : int);
  require_equal (module Int) !downstream_calls 1;
  (* @mdexp.end *)
  (* @mdexp

     5 to 7 is still odd. The parity node re-fires its own closure --- it
     has to, to find out --- but its cutoff absorbs the result, so
     `downstream` never even considers recomputing: *)
  (* @mdexp.code *)
  Cache.Var.set v 7;
  ignore (Cache.Node.value downstream : int);
  require_equal (module Int) !downstream_calls 1;
  (* @mdexp.end *)
  (* @mdexp

     7 to 8 flips the parity, and now the cutoff lets it through: *)
  (* @mdexp.code *)
  Cache.Var.set v 8;
  require_equal (module Int) (Cache.Node.value downstream) 0;
  require_equal (module Int) !downstream_calls 2;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ### both, and what the default cutoff can absorb

   A pair node is not special: it recomputes when a component moves, and
   its own cutoff then decides whether that counts. What is worth showing
   is where the *default* cutoff runs out.

   Two pairs over the same two vars, one left with the default cutoff
   and one given a structural `equal`, each with a reader counting how
   often it runs: *)

let%expect_test
    "both: the default cutoff can't absorb a re-allocated pair, an explicit equal can"
  =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let a = Cache.Var.create cache "x" in
  let b = Cache.Var.create cache "y" in
  let default_calls = ref 0 in
  let downstream_default =
    Cache.Node.map
      (Cache.Node.both (Cache.Var.watch a) (Cache.Var.watch b))
      ~f:(fun p ->
        incr default_calls;
        p)
  in
  let custom_calls = ref 0 in
  let custom_pair = Cache.Node.both (Cache.Var.watch a) (Cache.Var.watch b) in
  Cache.Node.set_cutoff custom_pair ~equal:(fun (a1, b1) (a2, b2) ->
    String.equal a1 a2 && String.equal b1 b2);
  let downstream_custom =
    Cache.Node.map custom_pair ~f:(fun p ->
      incr custom_calls;
      p)
  in
  ignore (Cache.Node.value downstream_default : string * string);
  ignore (Cache.Node.value downstream_custom : string * string);
  (* @mdexp.end *)
  (* @mdexp

     Now a freshly allocated string of the same content. `a`'s own watch
     node cannot cut it off --- a different block is a different block ---
     so both pairs recompute, even though neither pair's *content* has
     changed: *)
  (* @mdexp.code *)
  Cache.Var.set a (Bytes.to_string (Bytes.of_string "x"));
  ignore (Cache.Node.value downstream_default : string * string);
  ignore (Cache.Node.value downstream_custom : string * string);
  (* @mdexp.end *)
  (* @mdexp

     The difference is what each pair's cutoff does with that recompute.
     `phys_equal` cannot absorb the fresh tuple, so the default pair reports
     a change and its reader runs a second time; the structural `equal`
     absorbs it, and its reader does not: *)
  (* @mdexp.code *)
  require_equal (module Int) !default_calls 2;
  require_equal (module Int) !custom_calls 1;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   None of which is particular to pairing. Any `f` that allocates its
   result is in the same position, which is exactly when
   `Node.set_cutoff` is worth reaching for. *)

(* @mdexp

   ## const

   A node holding a value that never changes. It has no parent, so
   nothing can ever make it stale. *)

let%expect_test "const is a constant, never recomputed" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let n = Cache.Node.const cache 42 in
  require_equal (module Int) (Cache.Node.value n) 42;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Syntax

   `let+` and `and+` are `map` and `both` under applicative syntax, for
   combining more nodes than the `mapN` family covers. There is no `let*`
   --- the graph's shape is fixed where it is written, which is the
   trade this library makes.

   Over two vars holding 1 and 2: *)

let%expect_test "Syntax: let+/and+ over map/both" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let a = Cache.Var.create cache 1 in
  let b = Cache.Var.create cache 2 in
  let open Cache.Node.Syntax in
  let n =
    let+ a = Cache.Var.watch a
    and+ b = Cache.Var.watch b in
    a + b
  in
  require_equal (module Int) (Cache.Node.value n) 3;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Recomputing reads the clock, it does not tick it

   Only a write advances the clock. A node that recomputes stamps itself
   with the clock's *current* reading rather than minting a fresh one.

   That is what makes stamp comparison meaningful across the graph: a
   reading identifies the write that caused a change, not the order in
   which somebody happened to pull the nodes afterwards. *)

let%expect_test "recomputing reads the cache, it doesn't tick it: siblings share a stamp" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  Cache.Var.set v 2;
  (* @mdexp.end *)
  (* @mdexp

     Two independent nodes, both forced for the first time after that one
     write. Each stamps itself with the clock's current reading rather than
     minting one, so they end up sharing it instead of consuming a tick
     each: *)
  (* @mdexp.code *)
  let n1 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 10) in
  let n2 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 100) in
  ignore (Cache.Node.value n1 : int);
  ignore (Cache.Node.value n2 : int);
  require_equal
    (module Bool)
    (Cache.Private.Clock.Stamp.equal
       (Cache.Private.node_stamp n1)
       (Cache.Private.node_stamp n2))
    true;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## watch builds a fresh node every call

   Two `Var.watch` calls on the same var are two independent nodes, each
   with its own cached value and its own cutoff. Nothing memoizes one
   node per var. Sharing is the caller's business: keep whichever call's
   result and reuse it. *)

let%expect_test "watch builds a fresh node every call; share one by reusing it" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  require_equal (module Bool) (phys_equal (Cache.Var.watch v) (Cache.Var.watch v)) false;
  let shared = Cache.Var.watch v in
  require_equal (module Bool) (phys_equal shared shared) true;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Combining across caches is an error

   Stamps are only comparable within one clock, so a node combining
   parents from two different caches could not decide staleness at all.
   Rather than produce a node that quietly gets it wrong, `both` raises
   `Invalid_argument` at construction time. *)

let%expect_test "both raises when the two nodes don't share a cache" =
  (* @mdexp.code *)
  let a = Cache.Var.watch (Cache.Var.create (Cache.create ()) 1) in
  let b = Cache.Var.watch (Cache.Var.create (Cache.create ()) 2) in
  require_does_raise (fun () : (int * int) Cache.Node.t -> Cache.Node.both a b);
  [%expect {| Invalid_argument("Cache.Node: nodes were not built from the same clock") |}];
  (* @mdexp.end *)
  ()
;;

module Int_key = struct
  type t = int
  type comparator_witness

  let equal (a : int) b = a = b
  let hash = Stdlib.Hashtbl.hash

  (* Needed to build the [keys] sets below via [Set.of_list], and by
     [collect] itself to mint the empty [Map.t] its result starts from —
     [equal]/[hash] above are only for its own internal [table]. *)
  let compare a b = Ordering.of_int (Stdlib.Int.compare a b)
end

let keys_of li = Set.of_list (module Int_key) li

(* @mdexp

   ## collect

   `collect` is the one combinator whose parents are not fixed where it
   is written. Given a node holding a set of keys and a function `f` from
   key to node, it produces a node holding a map from key to value,
   tracking however many children the key set currently calls for.

   `f` is called the first time a key is seen and the resulting child is
   memoized, so a key that stays put is not rebuilt on every look. A key
   that leaves is dropped from the memo table and disconnected; if it
   later comes back, `f` mints a *fresh* child for it rather than
   resurrecting the old one --- which is what a caller wants when a key
   reappearing means the thing behind it was recreated, a deleted file
   written again under the same name being the motivating case.

   The test walks that whole life cycle. `f` mints one var per key,
   seeded to ten times the key, and `creates` counts how many times it
   was called: *)

let%expect_test "collect: a dynamic, keyed collection of nodes" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let keys = Cache.Var.create cache (keys_of [ 1; 2; 3 ]) in
  (* One [Cache.Var.t] per key, minted by [f] the first time [collect]
     asks for that key and remembered here so the test can mutate an
     individual child later without going through [f] again. *)
  let child_vars : (int, int Cache.Var.t) Hashtbl.t =
    Hashtbl.create (module Int_key) 16
  in
  let creates = ref 0 in
  let f k =
    incr creates;
    let v = Cache.Var.create cache (k * 10) in
    Hashtbl.set child_vars ~key:k ~data:v;
    Cache.Var.watch v
  in
  let node = Cache.Node.collect (module Int_key) ~keys:(Cache.Var.watch keys) ~f in
  let print () =
    let map = Cache.Node.value node in
    let pairs =
      List.map (Map.to_list map) ~f:(fun (k, v) -> Printf.sprintf "%d=%d" k v)
    in
    Printf.printf "[%s]\n" (String.concat ~sep:"; " pairs)
  in
  print ();
  [%expect {| [1=10; 2=20; 3=30] |}];
  require_equal (module Int) !creates 3;
  (* @mdexp.end *)
  (* @mdexp

     Reading again without any write re-mints nothing: *)
  (* @mdexp.code *)
  print ();
  [%expect {| [1=10; 2=20; 3=30] |}];
  require_equal (module Int) !creates 3;
  (* @mdexp.end *)
  (* @mdexp

     Changing one existing child's own var --- `keys` never moves --- is
     picked up without minting anything new. This is the whole point of
     `collect` over the coarse "watch one global signal" alternative: *)
  (* @mdexp.code *)
  Cache.Var.set (Hashtbl.find_exn child_vars 2) 99;
  print ();
  [%expect {| [1=10; 2=99; 3=30] |}];
  require_equal (module Int) !creates 3;
  (* @mdexp.end *)
  (* @mdexp

     Adding a key mints exactly one new child. The existing three are not
     re-minted --- same vars, same values, and `creates` goes to 4 rather
     than 7: *)
  (* @mdexp.code *)
  Cache.Var.set keys (keys_of [ 1; 2; 3; 4 ]);
  print ();
  [%expect {| [1=10; 2=99; 3=30; 4=40] |}];
  require_equal (module Int) !creates 4;
  (* @mdexp.end *)
  (* @mdexp

     Removing a key drops it from the result, and from the memo table
     behind it: *)
  (* @mdexp.code *)
  Cache.Var.set keys (keys_of [ 1; 3; 4 ]);
  print ();
  [%expect {| [1=10; 3=30; 4=40] |}];
  require_equal (module Int) !creates 4;
  (* @mdexp.end *)
  (* @mdexp

     And a key that comes back gets a fresh child from `f` rather than the
     old one resurrected. Key 2 returns holding 20, not the 99 the previous
     child for that key had been mutated to: *)
  (* @mdexp.code *)
  Cache.Var.set keys (keys_of [ 1; 2; 3; 4 ]);
  print ();
  [%expect {| [1=10; 2=20; 3=30; 4=40] |}];
  require_equal (module Int) !creates 5;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ### Unrelated writes leave it alone

   The dynamic parent set does not make `collect` promiscuous: a write to
   a var it never collected neither re-mints a child nor recomputes
   anything downstream. *)

let%expect_test "collect: an unrelated var's write doesn't force a recompute" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let keys = Cache.Var.create cache (keys_of [ 1 ]) in
  let unrelated = Cache.Var.create cache "x" in
  let creates = ref 0 in
  let recomputes = ref 0 in
  let node =
    Cache.Node.collect
      (module Int_key)
      ~keys:(Cache.Var.watch keys)
      ~f:(fun k ->
        incr creates;
        Cache.Node.const cache (k * 10))
  in
  let node =
    Cache.Node.map node ~f:(fun pairs ->
      incr recomputes;
      pairs)
  in
  ignore (Cache.Node.value node : (int, int, Int_key.comparator_witness) Map.t);
  Cache.Var.set unrelated "y";
  ignore (Cache.Node.value node : (int, int, Int_key.comparator_witness) Map.t);
  require_equal (module Int) !creates 1;
  require_equal (module Int) !recomputes 1;
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Deep chains, pulled part-way

   Writing is meant to be cheap, and it is kept cheap by a short-circuit:
   the marking pass stops as soon as it reaches a node that is already
   marked, on the strength of "already marked" implying "everything below
   it is marked too, and its edges were already cut". Get that wrong and
   a node stays stale-but-unmarked, serving an out-of-date value forever
   --- the one failure mode this design has that a full recompute does
   not.

   The invariant only becomes interesting once a chain is deep enough to
   sit half-resolved and half-marked at the same time, which no two- or
   three-node test can express. So, a chain of fifty: *)
let%expect_test "deep chain: partial pulls between writes" =
  (* @mdexp.code *)
  let cache = Cache.create () in
  let depth = 50 in
  let v = Cache.Var.create cache 0 in
  let nodes = Array.make (depth + 1) (Cache.Var.watch v) in
  for i = 1 to depth do
    nodes.(i) <- Cache.Node.map nodes.(i - 1) ~f:(fun x -> x + 1)
  done;
  let top = nodes.(depth) in
  require_equal (module Int) (Cache.Node.value top) depth;
  (* @mdexp.end *)
  (* @mdexp

     Write, then pull only the bottom half. The chain is now live up to the
     midpoint and marked above it --- the state no shallow test can
     reach: *)
  (* @mdexp.code *)
  Cache.Var.set v 10;
  require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (10 + (depth / 2));
  (* @mdexp.end *)
  (* @mdexp

     A second write cascades into exactly that mixed chain, and stops where
     it meets the marks. The nodes it never reached are the already-marked
     ones, and they must still recompute when the top is finally pulled: *)
  (* @mdexp.code *)
  Cache.Var.set v 100;
  require_equal (module Int) (Cache.Node.value top) (100 + depth);
  (* @mdexp.end *)
  (* @mdexp

     Everything is resolved again, and an ordinary write still travels the
     whole depth: *)
  (* @mdexp.code *)
  Cache.Var.set v 1000;
  require_equal (module Int) (Cache.Node.value top) (1000 + depth);
  (* @mdexp.end *)
  (* @mdexp

     Pulling from the middle afterwards changes nothing anywhere: *)
  (* @mdexp.code *)
  require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (1000 + (depth / 2));
  require_equal (module Int) (Cache.Node.value top) (1000 + depth);
  (* @mdexp.end *)
  ()
;;
