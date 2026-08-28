(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Test helpers

   `test/import.ml` is the small prelude every test file opens. It is not
   part of the library: it exists so the tests can say what they mean
   without pulling in a testing framework. This chapter covers the
   helpers themselves, so that a test failing tells you about the library
   rather than about the scaffolding.

   ## phys_equal

   Physical equality, the library's default cutoff. The test compares
   two structurally equal lists, built from an
   `Sys.opaque_identity`-hidden integer so that the compiler cannot
   recognise them as the same literal and share one block between them.
   Without that precaution a value can come out physically equal to
   another for reasons that have nothing to do with the code under
   test. *)

let%expect_test "phys_equal" =
  (* Built from an [Sys.opaque_identity]-hidden [n], so [a]/[b] can't be
     recognized as the same literal and shared at compile time — a plain
     [[ 1 ]] on each side would otherwise print [true] for both lines. *)
  let n = Sys.opaque_identity 1 in
  let a = [ n ] in
  let b = [ n ] in
  Printf.printf "%b\n" (phys_equal a a);
  Printf.printf "%b\n" (phys_equal a b);
  [%expect
    {|
    true
    false
    |}];
  ()
;;

(* @mdexp

   ## print_dyn

   Prints a `Dyn.t`, which is how a value reaches an expect-test snapshot
   here. *)

let%expect_test "print_dyn" =
  print_dyn (Dyn.int 42);
  [%expect {| 42 |}];
  ()
;;

(* @mdexp

   ## require_does_raise

   Runs `f`, printing the exception it raised --- the snapshot then pins
   which exception, and its message. If `f` returns instead, that is the
   failure, and `require_does_raise` raises `Failure "Did not raise."`.

   That failure path is itself worth a test, and it can be exercised
   without failing anything: an outer `require_does_raise` catches the
   `Failure` the inner one raises when its own `f` does not raise. *)

let%expect_test "require_does_raise: reports when [f] does not raise" =
  (* The outer [require_does_raise] catches the [Failure] the inner one
     raises when its own [f] doesn't — exercising that failure path
     without actually failing this test. *)
  require_does_raise (fun () -> require_does_raise (fun () -> ()));
  [%expect {| Failure("Did not raise.") |}];
  ()
;;

(* @mdexp

   ## require_equal

   Compares two values with a first-class module supplying `equal` and
   `to_dyn`. It is silent when they agree --- which is what makes it
   usable in bulk, several to a test, without an expect block after each
   one. *)

let%expect_test "require_equal: passes silently when the values are equal" =
  require_equal (module Int) 1 1;
  [%expect {| |}];
  ()
;;

(* @mdexp

   When they disagree it prints both sides before raising, so a failure
   report says what was expected and what actually came out, rather than
   only that something was wrong. That record is what a failing test in
   this suite prints. *)

let%expect_test "require_equal: reports both sides when the values are not equal" =
  require_does_raise (fun () -> require_equal (module Int) 1 2);
  [%expect
    {|
    { actual = 1; expected = 2 }
    Failure("Values are not equal.")
    |}];
  ()
;;
