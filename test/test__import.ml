(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

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

let%expect_test "print_dyn" =
  print_dyn (Dyn.int 42);
  [%expect {| 42 |}];
  ()
;;

let%expect_test "require_does_raise: reports when [f] does not raise" =
  (* The outer [require_does_raise] catches the [Failure] the inner one
     raises when its own [f] doesn't — exercising that failure path
     without actually failing this test. *)
  require_does_raise (fun () -> require_does_raise (fun () -> ()));
  [%expect {| Failure("Did not raise.") |}];
  ()
;;

let%expect_test "require_equal: passes silently when the values are equal" =
  require_equal (module Int) 1 1;
  [%expect {| |}];
  ()
;;

let%expect_test "require_equal: reports both sides when the values are not equal" =
  require_does_raise (fun () -> require_equal (module Int) 1 2);
  [%expect
    {|
    { actual = 1; expected = 2 }
    Failure("Values are not equal.")
    |}];
  ()
;;
