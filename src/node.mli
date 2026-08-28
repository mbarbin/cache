(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

open! Import

(*_ The user-facing doc lives on {!Cache.Node}, which restates this signature.
  [cache] here is [Types.cache] — the same handle {!Cache.create} mints,
  since [Cache.t]'s abstraction is a fiction [cache.mli] alone maintains.
  [t] is [Types.node] — manifest, not abstract, same as
  [Var.t]/[Types.var]: see [types.ml]'s header for why the two share a
  representation instead of each hiding its own from the other. *)

type 'a t = 'a Types.node

val value : 'a t -> 'a
val stamp : _ t -> Clock.Stamp.t
val const : Types.cache -> 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val map2 : 'a t -> 'b t -> f:('a -> 'b -> 'c) -> 'c t
val map3 : 'a t -> 'b t -> 'c t -> f:('a -> 'b -> 'c -> 'd) -> 'd t

(*_ Re-exported (not just used inline in [collect]'s own signature below)
  so [cache.ml]'s bare [module Node = Node] has something named [Key] to
  seal against {!Cache.Node}'s own independent [Key] declaration. *)
module type Key = Types.Key

val collect
  :  (module Key with type t = 'k and type comparator_witness = 'cmp)
  -> keys:('k, 'cmp) Set.t t
  -> f:('k -> 'v t)
  -> ('k, 'v, 'cmp) Map.t t

val set_cutoff : 'a t -> equal:('a -> 'a -> bool) -> unit

module Syntax : sig
  val return : Types.cache -> 'a -> 'a t
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
end

(*_ None of these three is exposed on {!Cache.Node} at all.

  [of_var] builds the exported [Cache.Var.watch]. Builds a fresh node
  reading [var]'s current value each call; nothing here memoizes one per
  var, so two callers wanting to share a node have to share the one
  [Cache.Var.watch] returned to whichever called it first — there is no
  entry point named [watch] here on purpose, that name is
  [Cache.Var.watch]'s alone.

  [computation] builds the node half of [Cache.Computation.t] — one with
  no real parent, driven instead by an [invalidate] call from outside.
  Just the node: pairing it with the closure that calls {!invalidate} on
  it, and giving that pair a name better than a bare tuple, is
  [computation.ml]'s job — see [types.ml]'s ['a computation] and
  [Computation]'s own [.mli] for why that's a module of its own, parallel
  to [Var], rather than a bare pair assembled at the [Cache.Computation]
  boundary.

  [assert_not_refreshing_exn] is what makes a {!Cache.Var.set} or a
  {!Cache.Computation.invalidate} issued from inside a node's own
  computation raise instead of silently losing the update — see
  [types.ml]'s [refreshing] field and [node.ml]'s [force].

  [invalidate] is [var.ml]'s and [computation.ml]'s shared entry point
  for telling (and disconnecting) whatever's watching something that just
  changed — a var that was [set], or a computation told from outside that
  its value needs recomputing. Both depend on [Node] for exactly this one
  function; [types.ml] holding the shared representation is what keeps
  that from being a cycle. *)
module Private : sig
  val of_var : 'a Types.var -> 'a t
  val computation : cache:Types.cache -> f:(unit -> 'a) -> 'a t
  val invalidate : 'a t -> unit
  val assert_not_refreshing_exn : Types.cache -> msg:string -> unit
end
