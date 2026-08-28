(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

open! Import

(*_ The user-facing doc lives on {!Cache.Computation}, which restates this
  signature. [t] is [Types.computation] — manifest, not abstract, same as
  [Var.t]/[Node.t] — a {!Node.t} with no real parent, driven instead by an
  external [invalidate] call, paired with the closure that makes that
  call. Parallel to [Var] on purpose: both are the library's "leaf, no
  real parent" kinds, each a plain record in [types.ml] plus a
  same-named module of operations over it. The [cache] {!create} takes
  is [Types.cache] — the same handle {!Cache.create} mints. *)

type 'a t = 'a Types.computation

val create : Types.cache -> f:(unit -> 'a) -> 'a t
val node : 'a t -> 'a Node.t
val invalidate : 'a t -> unit
