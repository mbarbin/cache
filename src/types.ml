(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(*_ [var]/[node]/[packed]/[shape], defined together in one recursive block,
  are what let a var's [children] hold real node pointers instead of the
  invalidating closures an earlier version of this used: a var is watched
  by nodes of many different result types, so [children] needs the same
  existential [packed] a node's own [children] does — [var]/[node] being
  in two separate files ([var.ml] can't depend on [node.ml]'s type, which
  itself depends on [var.ml]'s) is exactly what made that impossible
  before this module existed to give both a common home.

  Nothing here is hidden: [types.mli] mirrors this file's definitions
  field for field, manifest rather than abstract, so [var.ml] and
  [node.ml] can both reach in and read/write each other's fields directly
  (a var pushing straight onto a watching node's [children], say) without
  a round trip through function calls on either side. That's a deliberate
  trade — the two modules give up hiding their representation from each
  other — not a general loosening: [Cache.Var.t]/[Cache.Node.t] are still
  exactly as opaque to a caller of the library as before, since
  [cache.mli] re-abstracts both from scratch and never mentions [Types]
  at all. The per-field "what this means" documentation lives here, next
  to the fields; the "how the whole thing behaves" documentation —
  [refresh]/[connect]/[disconnect]/[invalidate] — lives in [node.ml],
  which is where that behavior actually happens. *)

(* [Collect]'s key needs all four: [equal]/[hash] to build and probe
   [table] (a [Hashtbl.t], read [node.ml]'s own doc for why that stays a
   Hashtbl rather than moving to the comparator-based [Set.t]/[Map.t]
   used for [keys]/the result), and [compare]/[comparator_witness] to
   mint the [Set.t] values [Collect] reads and the very first, empty
   result [Map.t] via {!Map.empty} on a [Collect] node's first
   [refresh] (when [cached] is still [None] — every [refresh] after
   that folds onto the previous result instead). *)
module type Key = sig
  type t
  type comparator_witness

  val equal : t -> t -> bool
  val hash : t -> int
  val compare : t -> t -> Ordering.t
end

(* The world a var or node belongs to — what {!Cache.t} actually is, and
   what {!Cache.create} mints one of. Its own named type, rather than a
   bare [Clock.t] used directly wherever "which world" needs threading
   (the way it used to be): [refreshing] below is the second piece of
   shared per-world state, and adding it was one field here rather than a
   rename cascade through every ['a var]/['a node] and every
   [~cache]-labeled constructor. *)
type cache =
  { clock : Clock.t
  ; mutable refreshing : bool
    (* Whether a {!Node.value} call is currently in flight anywhere in
       this world. Set for the duration of the outermost refresh (see
       [node.ml]'s [force]) and read by {!Var.set} and
       {!Cache.Computation.invalidate}, which raise rather than run
       while it holds: a node part-way through its own refresh is
       listed in its parents' [children] and still flagged
       [is_invalidated], and that is the one state in which
       {!invalidate}'s "already invalidated, therefore already told"
       short-circuit is wrong — the cascade would skip the node, cut
       the edge to it on the way past, and leave it resolved with a
       value computed from before the write, unreachable from that
       parent by any later write. Cheap to forbid outright (no [bind],
       so a closure has no legitimate reason to write), and there is no
       ordering within [refresh] that removes the window. Reads nest
       fine and are not affected: they tell no one anything. *)
  }

(* [var] and [node] deliberately share field names ([cache]/[stamp]/
   [children]) — they're the same concepts on both, and every use site
   has enough type context (the record it's built from, or a [: 'a var]/
   [: 'a node] annotation) for the compiler to pick the right one, so the
   only cost is this warning, silenced locally rather than worked around
   with an artificial prefix on one side. *)
[@@@warning "-30"]

type 'a var =
  { cache : cache
  ; mutable value : 'a
  ; mutable stamp : Clock.Stamp.t
    (* The clock reading as of [t]'s last [set], or {!Clock.Stamp.zero} if
       never set — {!Var.stamp}'s public doc. *)
  ; mutable children : packed list
    (* Nodes currently watching this var and resolved enough to care if it
       changes next — see the connect/disconnect discipline documented on
       {!node} below and in [node.ml]'s module doc. Every [set] hands this
       out and clears it in the same move: a var has no cutoff, so every
       write disconnects every current watcher unconditionally (only the
       watching node's own default cutoff then decides whether that
       reaches any further). *)
  }

and 'a node =
  { cache : cache
  ; mutable is_invalidated : bool
    (* [true]: this node hasn't been re-examined since something upstream
       last changed (or it has never been examined at all — a fresh
       node's starting state) — [refresh] must at least check, though
       checking may well conclude nothing needs to actually recompute.
       [false]: already checked as of the current state of the world;
       [refresh] returns [cached] straight off. A cheap, eagerly-propagated
       *maybe*, not a precise *definitely* — see [node.ml]'s module doc. *)
  ; mutable stamp : Clock.Stamp.t
    (* "Changed at": the reading as of the last time [refresh] produced a
       value the cutoff [equal] didn't consider the same as before. What a
       child compares its own [checked_at] against — see [refresh]. *)
  ; mutable checked_at : Clock.Stamp.t
    (* The reading as of the last time this node actually looked at its
       parents (whether or not that look changed [stamp]) — distinct from
       [stamp] precisely because of cutoff: if [equal] says the freshly
       computed value doesn't count as a change, [stamp] must not move
       (children shouldn't see a change), but [checked_at] still must, or
       the next look at this node would find the same parent "still" past
       it and recompute [f] again every time instead of settling. *)
  ; mutable cached : 'a option
  ; mutable equal : 'a -> 'a -> bool
    (* The cutoff: after [f] runs, an old and new value this [equal] to
       each other keep the old [cached] value, don't move [stamp], and
       don't reach any further than [checked_at] moving on this one node. *)
  ; mutable children : packed list
    (* Who currently reads from this node and is resolved enough to care
       if it changes — populated by [connect] as part of a *child's* own
       [refresh], emptied by [invalidate] as part of this node's own. *)
  ; shape : 'a shape
    (* What this node is built from and how it recombines its parents'
       values — everything [refresh] needs beyond the bookkeeping fields
       above. Reified as data rather than a closure so the whole family
       of constructors is one GADT a single function pattern-matches
       over. *)
  }

(* A ['a node] with its type parameter hidden — what a [children] list
   needs to hold a mix of nodes of different types; [Packed n]'s [n] is
   recovered locally, per use site, by pattern-matching. [@@unboxed]
   because there's exactly one constructor of exactly one argument: at
   runtime [Packed n] *is* [n], no separate wrapper block allocated to
   hold it — every [Packed t] {!Node.connect} conses onto a [children]
   list costs only the list cell, not a second allocation underneath it
   too. Node identity (used by [connect]/[disconnect] to tell two
   [packed] entries apart without a synthetic id field) still has to
   pattern-match [Packed n] out first before comparing, unboxed or not:
   what [@@unboxed] buys is not having to allocate to *produce* a
   [packed], not a way to compare two of them without looking inside. *)
and packed = Packed : 'a node -> packed [@@unboxed]

(* One constructor per way a node can be built. Each carries exactly the
   parent node(s) it reads and the function it recombines their values
   with. Parent types (the shape's own type parameters that don't appear
   in its result type — ['p] in [Map], ['p1]/['p2] in [Map2], etc.) are
   existentially quantified: [refresh] recovers each one locally, per
   branch, by pattern-matching. [Map]/[Map2]/[Map3] are grouped last,
   together, so a future [Map4] (etc.) slots in right after [Map3]
   instead of splitting up the non-map constructors above. Multi-field
   constructors take an inline record rather than a positional tuple —
   [Map2]'s three fields, say, are easy to transpose silently as a tuple
   and a compile error the moment they aren't as a record. *)
and _ shape =
  | Const : 'a -> 'a shape
  | Var : 'a var -> 'a shape
  | Collect :
      { key_module : (module Key with type t = 'k and type comparator_witness = 'cmp)
        (* Kept as a field rather than consumed once at construction:
           {!Node.refresh}'s [Collect] branch needs it again on the
           node's first [refresh] (when [cached] is still [None]) to
           mint the starting, empty result [Map.t] via {!Map.empty}.
           Every [refresh] after that folds onto the previous result,
           and never reads it again. *)
      ; keys : ('k, 'cmp) Set.t node
      ; f : 'k -> 'v node
      ; table : ('k, 'v node) Hashtbl.t
        (* The memoization table lives here, in the shape, rather than
           captured in a closure's environment: {!Node.refresh} is the
           only thing that reads or mutates it, and as a field that stays
           one pattern-match away instead of behind a function call. *)
      }
      -> ('k, 'v, 'cmp) Map.t shape
  | Computation : (unit -> 'a) -> 'a shape
    (* No real parent to compare a stamp against, so staleness is driven
       entirely by [is_invalidated] itself — the [invalidate] closure a
       computation's constructor hands back is the only thing that ever
       moves it off [false], and unlike every other shape there's no
       sharper "did it actually change" question to ask underneath that:
       an external invalidation always means recompute. *)
  | Map :
      { a : 'p node
      ; f : 'p -> 'a
      }
      -> 'a shape
  | Map2 :
      { a : 'p1 node
      ; b : 'p2 node
      ; f : 'p1 -> 'p2 -> 'a
      }
      -> 'a shape
  | Map3 :
      { a : 'p1 node
      ; b : 'p2 node
      ; c : 'p3 node
      ; f : 'p1 -> 'p2 -> 'p3 -> 'a
      }
      -> 'a shape

(* A node with no real parent (the [shape] case right above), paired with
   the closure that drives it — [computation.ml]'s ['a t], the type
   [Cache.Computation.t] is. Not part of the [and] block above: nothing
   there needs to know this exists (a [node]'s [Computation] shape is just
   [unit -> 'a], no closure or bundle in sight), only this needs to know
   [node] — same shape var and node are already in, one direction only.
   Defined here rather than assembled ad hoc where it's used (as it used
   to be, inline in [cache.ml]) so [Var]/[Computation] — the library's two
   "no real parent" leaf kinds — are structurally parallel: a plain
   record type here, a same-named module ([var.ml]/[computation.ml])
   providing the operations over it, [cache.ml] mostly just re-exporting
   that module rather than building logic of its own. *)
type 'a computation =
  { node : 'a node
  ; invalidate : unit -> unit
  }
