(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

let%expect_test "watch reflects the var's current value" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  let n = Cache.Var.watch v in
  require_equal (module Int) (Cache.Node.value n) 1;
  Cache.Var.set v 2;
  require_equal (module Int) (Cache.Node.value n) 2;
  ()
;;

let%expect_test "a unit Var used as a pure signal needs its cutoff disabled" =
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
  (* [unit] is [phys_equal] to itself always, so the default cutoff on
     [signal_node] swallows this [set]: [n] never recomputes. *)
  Cache.Var.set signal ();
  require_equal (module Int) (Cache.Node.value n) 1;
  (* Disabling [signal_node]'s cutoff makes every [set] count. *)
  Cache.Node.set_cutoff signal_node ~equal:(fun () () -> false);
  Cache.Var.set signal ();
  require_equal (module Int) (Cache.Node.value n) 2;
  ()
;;

let%expect_test "map only recomputes when the parent's stamp moved" =
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
  ()
;;

let%expect_test "an unrelated var's write doesn't force a recompute" =
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
  ()
;;

(* [map2]/[map3] and the rest of the [mapN] family get their own,
   systematic, per-component coverage in [test__mapn.ml] rather than a
   one-off case each here — see that file's header. *)

let%expect_test "cutoff stops a downstream recompute when the value didn't really change" =
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
  (* 5 -> 7 is still odd: [mid] re-fires its own closure (it has to, to
     find out), but its cutoff absorbs the result, so [downstream] never
     even considers recomputing. *)
  Cache.Var.set v 7;
  ignore (Cache.Node.value downstream : int);
  require_equal (module Int) !downstream_calls 1;
  (* 7 -> 8 flips parity: now [mid]'s cutoff lets it through. *)
  Cache.Var.set v 8;
  require_equal (module Int) (Cache.Node.value downstream) 0;
  require_equal (module Int) !downstream_calls 2;
  ()
;;

let%expect_test
    "both's default cutoff rarely fires (fresh pair every time); set_cutoff does"
  =
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
  (* A freshly-allocated string with the same content: [a]'s own watch
     node isn't [phys_equal]-cut-off (it's a different block), so both
     variants of [both] see it as stale and recompute the pair — but the
     pair's *content* hasn't actually changed. *)
  Cache.Var.set a (Bytes.to_string (Bytes.of_string "x"));
  ignore (Cache.Node.value downstream_default : string * string);
  ignore (Cache.Node.value downstream_custom : string * string);
  require_equal (module Int) !default_calls 2;
  require_equal (module Int) !custom_calls 1;
  ()
;;

let%expect_test "const is a constant, never recomputed" =
  let cache = Cache.create () in
  let n = Cache.Node.const cache 42 in
  require_equal (module Int) (Cache.Node.value n) 42;
  ()
;;

let%expect_test "Syntax: let+/and+ over map/both" =
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
  ()
;;

let%expect_test "recomputing reads the cache, it doesn't tick it: siblings share a stamp" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  Cache.Var.set v 2;
  (* Two independent nodes, both forced for the first time after the
     same single write: each stamps itself with the cache's current
     reading, not a freshly-minted one, so they end up sharing it rather
     than each consuming its own tick. *)
  let n1 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 10) in
  let n2 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 100) in
  ignore (Cache.Node.value n1 : int);
  ignore (Cache.Node.value n2 : int);
  require_equal
    (module Bool)
    (Cache.Clock.Stamp.equal (Cache.Node.stamp n1) (Cache.Node.stamp n2))
    true;
  ()
;;

let%expect_test "watch builds a fresh node every call; share one by reusing it" =
  let cache = Cache.create () in
  let v = Cache.Var.create cache 1 in
  (* Two separate [watch] calls are two independent nodes — sharing one
     (its cache, its cutoff) is on the caller: keep and reuse whichever
     call's result instead of calling [watch] again. *)
  require_equal (module Bool) (phys_equal (Cache.Var.watch v) (Cache.Var.watch v)) false;
  let shared = Cache.Var.watch v in
  require_equal (module Bool) (phys_equal shared shared) true;
  ()
;;

let%expect_test "both raises when the two nodes don't share a cache" =
  let a = Cache.Var.watch (Cache.Var.create (Cache.create ()) 1) in
  let b = Cache.Var.watch (Cache.Var.create (Cache.create ()) 2) in
  require_does_raise (fun () : (int * int) Cache.Node.t -> Cache.Node.both a b);
  [%expect {| Invalid_argument("Cache.Node: nodes were not built from the same clock") |}];
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

let%expect_test "collect: a dynamic, keyed collection of nodes" =
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
  (* Reading again without any write doesn't re-mint any child. *)
  print ();
  [%expect {| [1=10; 2=20; 3=30] |}];
  require_equal (module Int) !creates 3;
  (* Changing one existing child's own var — [keys] never moves — is
     picked up without minting anything new: the whole point of
     [collect] over the coarse "watch one global signal" alternative. *)
  Cache.Var.set (Hashtbl.find_exn child_vars 2) 99;
  print ();
  [%expect {| [1=10; 2=99; 3=30] |}];
  require_equal (module Int) !creates 3;
  (* Adding a key mints exactly one new child; the existing two aren't
     re-minted (same [Cache.Var.t]s, same values). *)
  Cache.Var.set keys (keys_of [ 1; 2; 3; 4 ]);
  print ();
  [%expect {| [1=10; 2=99; 3=30; 4=40] |}];
  require_equal (module Int) !creates 4;
  (* Removing a key drops it from both the result and the memoization
     table. *)
  Cache.Var.set keys (keys_of [ 1; 3; 4 ]);
  print ();
  [%expect {| [1=10; 3=30; 4=40] |}];
  require_equal (module Int) !creates 4;
  (* A key that reappears after being dropped gets a fresh child via
     [f] rather than resurrecting the old one (its value starts back at
     [k * 10], not the [99] the old child for key 2 was mutated to). *)
  Cache.Var.set keys (keys_of [ 1; 2; 3; 4 ]);
  print ();
  [%expect {| [1=10; 2=20; 3=30; 4=40] |}];
  require_equal (module Int) !creates 5;
  ()
;;

let%expect_test "collect: an unrelated var's write doesn't force a recompute" =
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
  ()
;;

(* A long chain, pulled only part-way between writes. This is the shape
   the eager marking pass's short-circuit rests on: it stops at a node
   already marked, on the strength of "already marked" implying "its
   children were already cut, and everything below it is marked too".
   That invariant is only interesting once a chain is deep enough to sit
   half-resolved and half-marked at the same time, which the two- and
   three-level tests above can't express. *)
let%expect_test "deep chain: partial pulls between writes" =
  let cache = Cache.create () in
  let depth = 50 in
  let v = Cache.Var.create cache 0 in
  let nodes = Array.make (depth + 1) (Cache.Var.watch v) in
  for i = 1 to depth do
    nodes.(i) <- Cache.Node.map nodes.(i - 1) ~f:(fun x -> x + 1)
  done;
  let top = nodes.(depth) in
  require_equal (module Int) (Cache.Node.value top) depth;
  (* Write, then resolve only the bottom half of the chain: the top half
     stays marked and disconnected while the bottom half is live again. *)
  Cache.Var.set v 10;
  require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (10 + (depth / 2));
  (* A second write now cascades into a chain that is resolved up to the
     halfway point and already marked past it — where it stops. The
     nodes it didn't reach are the ones that were already marked, and
     they must still recompute when finally pulled. *)
  Cache.Var.set v 100;
  require_equal (module Int) (Cache.Node.value top) (100 + depth);
  (* And once everything is resolved again, an ordinary write still
     travels the whole depth. *)
  Cache.Var.set v 1000;
  require_equal (module Int) (Cache.Node.value top) (1000 + depth);
  (* Pulling from the middle after that changes nothing anywhere. *)
  require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (1000 + (depth / 2));
  require_equal (module Int) (Cache.Node.value top) (1000 + depth);
  ()
;;
