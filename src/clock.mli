(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

open! Import

(*_ The user-facing doc lives on {!Cache.Clock}, which restates this signature. *)

type t

module Stamp : sig
  type t

  val zero : t
  val equal : t -> t -> bool
  val ( > ) : t -> t -> bool
  val to_dyn : t -> Dyn.t
end

val create : unit -> t

(*_ Settles on the reading the writes since the last recompute reserved,
  and returns it. Named for the transition, not for the reading: there
  is no way to look at this clock without moving it. See [clock.ml] for
  why committing here, at the moment a node stamps itself, is what makes
  {!reserve}'s sharing safe. *)
val settle : t -> Stamp.t

(*_ The reading a write announces itself by. Shared with every other
  write up to the next {!settle}, rather than one taken per write. *)
val reserve : t -> Stamp.t
