(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

(* @mdexp

   # pulicomv

   [![CI Status](https://github.com/mbarbin/cache/workflows/ci/badge.svg)](https://github.com/mbarbin/cache/actions/workflows/ci.yml)
   [![Coverage Status](https://coveralls.io/repos/github/mbarbin/cache/badge.svg?branch=main)](https://coveralls.io/github/mbarbin/cache?branch=main)

   **Pul**l-based **i**ncremental **co**mputation over **m**utable **v**ars.

   ## The question

   This project started from a question: what would you write if you
   wanted pull-based, on-demand incremental computation, with no full
   stabilization pass, and you didn't need the power of `bind`? If you're
   ready to give up on `bind`, can you end up with something simpler than
   Jane Street's
   [incremental](https://github.com/janestreet/incremental)?

   pulicomv is an attempt to explore and answer that question. *)

(* @mdexp.code *)

let%expect_test "pulling a node" =
  let cache = Cache.create () in
  let width = Cache.Var.create cache 3 in
  let height = Cache.Var.create cache 4 in
  let area =
    Cache.Node.map2 (Cache.Var.watch width) (Cache.Var.watch height) ~f:(fun w h ->
      print_endline "computing the area";
      w * h)
  in
  (* Building a node computes nothing: it's the read that pulls. *)
  [%expect {| |}];
  print_endline (Int.to_string (Cache.Node.value area));
  [%expect
    {|
    computing the area
    12
    |}];
  (* Reading again, with the world unchanged, is a cache hit. *)
  print_endline (Int.to_string (Cache.Node.value area));
  [%expect {| 12 |}];
  (* A write marks what's downstream of it, and recomputes nothing. *)
  Cache.Var.set width 5;
  [%expect {| |}];
  (* The next read is what pays for it. *)
  print_endline (Int.to_string (Cache.Node.value area));
  [%expect
    {|
    computing the area
    20
    |}];
  ()
;;

(* @mdexp

   ## The shape of the answer

   Giving up `bind` means a node's parents are fixed when it is built, so
   the graph can only ever be grown bottom-up from nodes that already
   exist. That one restriction is what pays for the rest: there is no
   topological ordering to maintain, no node heights, no priority queue, no
   scheduler -- and no way to build a cycle in the first place.

   What's left is two passes, neither of them a stabilization:

   - **On write**, eagerly: `Var.set` ticks a shared clock and marks
     everything currently reading from it "maybe stale", transitively. No
     value is recomputed, no closure runs. This is an *invalidation* pass,
     and its whole job is to let a later read that finds nothing has moved
     return without touching its parents at all. It also cuts the edges it
     walks: a node it marks drops out of its parents' child lists, and puts
     itself back only when it is next pulled and resolves. So the pass
     reaches only the part of the graph that has actually been read back
     since the last write -- and a second write, with no read in between,
     finds nothing connected left to mark and costs essentially nothing.
     Writes in a burst get cheaper as the burst goes on.
   - **On read**, lazily: `Node.value` is what actually checks. If the node
     isn't marked, the cached value stands. If it is, the node refreshes
     its own parents first -- reconnecting to each as it goes -- and
     compares their stamps against what it last saw; only a parent that
     really moved re-fires the closure. So a diamond never observes a
     half-updated world, and a node nobody pulls is never computed.

   Per-node cutoffs (`Node.set_cutoff`, `phys_equal` by default) decide
   whether a recompute counts as a change downstream, so a value that
   churns without really changing stops there.

   Two escape hatches keep the static graph from being too rigid a deal:
   `Node.collect` depends on however many keys a key set currently holds
   (one memoized child node per key) rather than on a lexically fixed
   number of parents, and `Cache.Computation` is a leaf driven by an
   external, imperative `invalidate` call -- for caching something
   expensive to re-derive without paying for it on every write.

   See `cache.mli` for the full API and the design notes behind it.

   ## See also

   Other OCaml takes on incremental and reactive computation:

   - [incremental](https://github.com/janestreet/incremental) -- the full
     self-adjusting-computation engine this one is a small answer to:
     `bind`, an explicit `stabilize`, observers.
   - [incr_map](https://github.com/janestreet/incr_map) -- incremental
     operations over maps, on top of `incremental`.
   - [current_incr](https://github.com/ocurrent/current_incr) -- a small
     self-adjusting computation library.
   - [par_incr](https://github.com/ocaml-multicore/par_incr) -- parallel
     self-adjusting computation.
   - [prbnmcn-cgrph](https://github.com/igarnier/prbnmcn-cgrph) --
     incremental computation over a graph of cells.
   - [lwd](https://github.com/let-def/lwd) -- the nearest neighbour of
     this design: vars, applicative combinators, invalidation on set,
     recomputation on demand. It keeps `bind`, computes only under
     explicit `observe`/`sample` roots that are released by hand, and has
     no per-node cutoff.
   - [react](https://erratique.ch/software/react) and
     [note](https://erratique.ch/software/note) -- declarative events and
     signals.

   ## Acknowledgments

   pulicomv shares no code with
   [incremental](https://github.com/janestreet/incremental), but it does
   borrow its vocabulary -- the `Var` / `Node` split, `Var.watch`, the
   `cutoff` that decides whether a recompute counts as a change downstream
   -- and it was written with `incremental`'s design in view throughout:
   the question above is one this project could only ask because Jane
   Street answered the harder version of it first, in the open. Thanks to
   Jane Street for releasing it.

   A copy of `incremental`'s MIT license is included in this repository at
   `third-party-license/janestreet/incremental/LICENSE.md`; see
   [NOTICE.md](NOTICE.md) for details.

   ## Naming is hard: pulicomv vs Cache?

   The opam package is named `pulicomv` -- a publishing name, picked to
   be unique and not to read as a sibling of a package name already
   taken; it spells out the tagline above. The library's main module and
   entry point is named `Cache`, and that's what call sites are expected
   to use. The repository is named after the module rather than the
   package, so that renaming the package stays a local change to the
   `.opam` files.

   ## Status

   Currently under test and review. Not published.
*)
