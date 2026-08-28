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
val now : t -> Stamp.t
val tick : t -> Stamp.t
