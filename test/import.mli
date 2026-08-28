(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

(*_ Small private prelude (no [public_name] — nothing outside this project
  depends on it) for the handful of things these tests need beyond plain
  [Stdlib]: labelled [List]/[String] aliases, [Int]/[Bool]/[String]
  extended with [to_dyn] (for {!require_equal}), [print_dyn],
  [phys_equal], and [require_equal]/[require_does_raise]. Not a
  general-purpose stdlib extension — grow it only when a test itself
  needs something new. *)

val phys_equal : 'a -> 'a -> bool

module List : sig
  include module type of ListLabels
end

module String : sig
  include module type of StringLabels

  val to_dyn : t -> Dyn.t
end

module Int : sig
  include module type of Int

  val to_dyn : t -> Dyn.t
end

module Bool : sig
  include module type of Bool

  val to_dyn : t -> Dyn.t
end

val print_dyn : Dyn.t -> unit

(** [require_does_raise f] raises [Failure "Did not raise."] if [f ()]
    does not raise, and otherwise prints the exception — for expect
    tests exercising this library's own invariant checks. *)
val require_does_raise : (unit -> 'a) -> unit

(** What {!require_equal} needs from a value's type: [equal] to compare,
    [to_dyn] to print both sides if they don't match. *)
module type With_equal_and_dyn = sig
  type t

  val equal : t -> t -> bool
  val to_dyn : t -> Dyn.t
end

(** [require_equal (module M) actual expected] raises
    [Failure "Values are not equal."] (after printing both sides via
    [M.to_dyn]) unless [M.equal actual expected] — used in place of
    printing [actual] and asserting it via [%expect] wherever [expected]
    is already a literal value the test can just state directly: unlike
    an [%expect] block, a wrong literal here can't get silently accepted
    by [dune promote]. *)
val require_equal : (module With_equal_and_dyn with type t = 'a) -> 'a -> 'a -> unit
