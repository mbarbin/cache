(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

(*_ Small private prelude (no [public_name] — nothing outside this project
  depends on it) for the two things [Cache] needs beyond plain [Stdlib]:
  a labelled [List] and [phys_equal] (used in several places, and
  [Node]'s default cutoff besides). Not a general-purpose stdlib
  extension — grow it only when [Cache] itself needs something new. *)

val phys_equal : 'a -> 'a -> bool

module List : sig
  include module type of ListLabels
end
