(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

(** Pull-based incremental computation over mutable vars.

    A {!Var.t} holds mutable state. A {!Node.t} is a memoized computation
    over vars and other nodes, built with the applicative combinators
    ({!Node.map}, {!Node.map2}, {!Node.collect}, …) and forced with
    {!Node.value}. Values are computed when they are read, not when
    their inputs change.

    Three rules describe the model:

    - A write ({!Var.set}, {!Computation.invalidate}) marks what is
      downstream of it as possibly stale, and recomputes nothing.
    - A read ({!Node.value}) is what recomputes, and only what it needs:
      a node whose inputs haven't moved returns its cached value without
      consulting them.
    - Whether a recompute counts as a change for the nodes below is
      decided by that node's {e cutoff} ({!Node.set_cutoff}, [phys_equal]
      by default).

    Recomputation happens only inside a {!Node.value} call — there is no
    separate pass over the graph — so a node nobody reads is never
    computed.

    {1 The one restriction}

    {!Var.set} and {!Computation.invalidate} must not be called from
    inside a node's own computation — from the [f] of a {!Node.map}, or
    of a {!Computation.create}. Both raise [Invalid_argument] if they
    are, because the update would otherwise be silently lost.

    Reading other nodes from inside an [f] is allowed and does not raise,
    but it creates no dependency: a node depends on what it was built
    from, so a {!Node.value} or {!Var.peek} inside an [f] goes untracked
    and won't make that node stale. Compose with {!Node.map2} and friends
    to make it one. *)

open! Import

(** One "world". Every {!Var.t} and {!Node.t} that gets combined together
    has to come from the same [t] — {!Node.map2} and friends raise
    [Invalid_argument] on nodes from two different caches. Create one
    with {!create} and thread it through. *)
type t

(*_ Another name for [t], so the [Var]/[Node]/[Computation] signatures
  below can name it where their own [t] would shadow it. *)
type cache := t

(** A fresh, empty cache. *)
val create : unit -> t

module Clock : sig
  (** The logical clock shared by every var and node of one cache.

      Most code never needs this module: it is here because comparing
      stamps is occasionally useful — {!Node.stamp} says when a node's
      value last changed. *)

  type t

  (** A reading of the clock: a var's or node's "as of" version. Abstract
      so it can't be mistaken for an unrelated [int]. *)
  module Stamp : sig
    type t

    (** Where every var and node starts, before its first write or
        computation. *)
    val zero : t

    val equal : t -> t -> bool

    (** [a > b] — [a] is a later reading than [b]. *)
    val ( > ) : t -> t -> bool

    val to_dyn : t -> Dyn.t
  end

  (** The current reading. Does not advance the clock. *)
  val now : t -> Stamp.t

  (** Advances the clock by one and returns the new reading. Within the
      library only {!Var.set} and {!Computation.invalidate} call this. *)
  val tick : t -> Stamp.t
end

module Node : sig
  (** A memoized computation over vars and other nodes.

      Build nodes with {!Var.watch} and the combinators below, then force
      them with {!value}. A node holds its parents, the closure that
      recombines their values, and the last value it computed; forcing it
      re-runs that closure only when a parent has actually changed since
      this node last looked at it. *)

  type 'a t

  (** Forces the node: recomputes if an input has changed since the last
      look, otherwise returns the cached value. *)
  val value : 'a t -> 'a

  (** When this node's value last changed, as judged by its
      {!set_cutoff}. Forces the node, exactly as {!value} does. *)
  val stamp : _ t -> Clock.Stamp.t

  (** A node that never changes; [v] is never recomputed. [cache] only
      says which world it belongs to. *)
  val const : cache -> 'a -> 'a t

  val map : 'a t -> f:('a -> 'b) -> 'b t

  (** [both a b] is [map2 a b ~f:(fun a b -> a, b)]. *)
  val both : 'a t -> 'b t -> ('a * 'b) t

  (** Reads two parents through one node. Preferred over {!map} composed
      with {!both}, which allocates an intermediate pair node and costs
      an extra check per level. *)
  val map2 : 'a t -> 'b t -> f:('a -> 'b -> 'c) -> 'c t

  (** Three-parent {!map2}. *)
  val map3 : 'a t -> 'b t -> 'c t -> f:('a -> 'b -> 'c -> 'd) -> 'd t

  (** What {!collect} needs of a key: [equal]/[hash] for its internal
      table of child nodes, [compare]/[comparator_witness] for the
      [Set.t] it reads and the [Map.t] it produces. Any [Set.t]/[Map.t]
      key module already has all four. *)
  module type Key = sig
    type t
    type comparator_witness

    val equal : t -> t -> bool
    val hash : t -> int
    val compare : t -> t -> Ordering.t
  end

  (** [collect (module Key) ~keys ~f] depends on however many keys [keys]
      currently holds, rather than on a number fixed where the code is
      written: one child node per key, built by [f] the first time that
      key is seen and then memoized, dropped once the key leaves [keys]
      (so a key that reappears gets a fresh child, never a stale one).
      The result is stale exactly when [keys] changes or a
      currently-tracked child does.

      In the resulting [Map.t], a key whose child didn't change keeps the
      binding it already had, physically unchanged — so a {!map} reading
      one key out of the result can cut off when a {e different} key
      changes.

      [keys] has to be a node itself ({!Var.watch} a var holding the set,
      or {!map} one), or the collection's membership is never seen to
      change. *)
  val collect
    :  (module Key with type t = 'k and type comparator_witness = 'cmp)
    -> keys:('k, 'cmp) Set.t t
    -> f:('k -> 'v t)
    -> ('k, 'v, 'cmp) Map.t t

  (** {1 Cutoff} *)

  (** [set_cutoff t ~equal] decides when a recompute of [t] counts as a
      change for the nodes built from [t]: once a recompute produces a
      value [equal] to the one cached, [t]'s {!stamp} stays put and
      nothing downstream recomputes. The first computation always counts
      as a change, there being no earlier value to compare it against.

      The default, [phys_equal], already suits ordinary functional code:
      an [f] that passes an unchanged input straight through, or returns
      one of its own arguments, cuts off for free. Set an explicit
      [equal] when a value has more than one representation of what is
      conceptually the same thing — a record rebuilt field by field, or a
      value arriving freshly parsed from somewhere each time.

      Two things worth knowing. The default never fires on {!both} (nor
      on {!Syntax}'s [and+]): the pair is allocated afresh on every
      recompute, so it always reports a change, and any cutting off has
      to happen on the nodes either side of it. And a cutoff set on the
      node {!Var.watch} returned applies to every reader sharing that
      node, not only the caller that set it.

      A mutation rather than a constructor: it returns [unit], so it
      never reads as though it had built a new node. *)
  val set_cutoff : 'a t -> equal:('a -> 'a -> bool) -> unit

  module Syntax : sig
    (** [let+]/[and+] over {!map}/{!both}, for the arities
        {!map2}/{!map3} don't cover. [and+] builds a {!both}, whose
        default cutoff never fires — see {!set_cutoff}. *)

    val return : cache -> 'a -> 'a t
    val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
    val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  end
end

module Computation : sig
  (** A node with no var or node parent, driven by an explicit
      {!invalidate} call instead — for caching something expensive to
      re-derive from state this library can't see into (a large file's
      parsed contents, say).

      Bundles the node together with its [invalidate] closure, so a
      caller carries one value rather than a pair. *)

  type 'a t

  (** [create cache ~f] is a computed cell. [f] runs lazily, on the next
      {!Node.value} of {!val-node}, and only if {!invalidate} has been
      called since it last ran. {!invalidate} never runs [f] itself: call
      it wherever the underlying thing changes, and let whichever read
      needs the fresh value pay for it, once. *)
  val create : cache -> f:(unit -> 'a) -> 'a t

  (** The underlying node, to read with {!Node.value} or compose further
      with {!Node.map} and friends. *)
  val node : 'a t -> 'a Node.t

  (** Marks [t] stale, so the next {!Node.value} of {!val-node} re-runs
      [f]. Raises [Invalid_argument] if called from inside a node's
      computation — see the restriction at the top of this page. *)
  val invalidate : 'a t -> unit
end

module Var : sig
  (** The mutable leaf a {!Node.t} is ultimately derived from, via
      {!watch}. *)

  type 'a t

  (** [create cache v] is a var holding [v]. Creating one is not a write:
      it does not advance the clock. *)
  val create : cache -> 'a -> 'a t

  (** The value currently held, read directly: no dependency recorded, no
      recompute. Deliberately not named [value], to keep it visibly a
      different operation from {!Node.value}. *)
  val peek : 'a t -> 'a

  (** Replaces the value and marks every node downstream as possibly
      stale. Recomputes nothing. Raises [Invalid_argument] if called from
      inside a node's computation — see the restriction at the top of
      this page. *)
  val set : 'a t -> 'a -> unit

  (** When [t] was last {!set}, or {!Clock.Stamp.zero} if it never was. *)
  val stamp : _ t -> Clock.Stamp.t

  (** A node reading [t]'s current value.

      Every call builds a {b fresh} node. To share one between several
      readers — and with it the cached value and the cutoff — keep the
      node that one [watch] call returned and pass that around.

      {b Note.} Under the default [phys_equal] cutoff, a var whose type
      has essentially one value never looks changed to its watchers: a
      [unit Var.t] used as a "something happened" signal needs
      [Node.set_cutoff (watch t) ~equal:(fun _ _ -> false)] on the node,
      so that every {!set} counts. *)
  val watch : 'a t -> 'a Node.t
end

(** The clock this cache shares — see {!Clock}. *)
val clock : t -> Clock.t
