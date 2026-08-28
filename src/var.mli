(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

open! Import

(*_ The minimal mutable leaf: a value plus its clock stamp and its current
  watchers, with no knowledge of {!Node.shape} — [t] is [Types.var]
  (manifest, not abstract: see [types.ml]'s header for why this and
  [Node.t] share a representation instead of each hiding its own from the
  other). [cache.ml] is what rebinds the exported [Cache.Var] with the
  [watch] function built from {!Node.Private.of_var}; the user-facing doc
  for all of this, [watch] included, lives on {!Cache.Var}. The [cache]
  {!create} takes is [Types.cache] — the same handle {!Cache.create}
  mints. *)

type 'a t = 'a Types.var

val create : Types.cache -> 'a -> 'a t
val peek : 'a t -> 'a
val set : 'a t -> 'a -> unit
val stamp : _ t -> Clock.Stamp.t
