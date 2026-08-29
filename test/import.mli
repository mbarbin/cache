(*_********************************************************************************)
(*_  pulicomv - pull-based incremental computation over mutable vars              *)
(*_  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*_  SPDX-License-Identifier: ISC                                                 *)
(*_********************************************************************************)

(*_ Small private prelude (no [public_name] — nothing outside this project
  depends on it) for the handful of things these tests need beyond plain
  [Stdlib]: labelled [List]/[String] aliases, [Int]/[Bool]/[String]
  extended with [to_dyn] (for {!require_equal}), [Int] extended further
  into the key module [Cache.Node.collect] asks for, [print_dyn],
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

(** Like {!String} and {!Bool} either side of it, this re-exports
    [Stdlib.Int] wholesale, so that everything the standard library
    already says about an integer stays reachable through the prelude.
    What follows the include is what the tests ask of an integer beyond
    that — including a [compare] that shadows [Stdlib.Int]'s. *)
module Int : sig
  include module type of Int

  (** [equal], from the include above, and [to_dyn] are what
      {!require_equal} needs. *)

  val to_dyn : t -> Dyn.t

  (** [hash], [compare] and [comparator_witness] are what
      [Cache.Node.collect] asks of a key type: [equal] and [hash] for the
      table it memoizes children in, [compare] and [comparator_witness]
      for the key [Set.t] it reads and the [Map.t] it returns. Passing
      [(module Int)] to [collect], to [Hashtbl.create] and to
      [Set.of_list] alike is what keeps the chapters testing [collect]
      over one notion of an integer key rather than over a key module
      each. [compare] here shadows the [int]-returning one included
      above: a key module is asked for an [Ordering.t], and no test
      wants the other. *)

  type comparator_witness

  val hash : t -> int
  val compare : t -> t -> Ordering.t
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
