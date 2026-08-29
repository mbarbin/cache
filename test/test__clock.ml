(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(* @mdexp

   # Clock

   Every var and node carries a *stamp*: a reading of the one logical
   clock its cache holds. A node compares a parent's stamp against the
   reading at which it itself last looked, and that comparison is the
   whole of how it decides whether it has anything to do.

   This chapter is the clock on its own, with no var and no node in
   sight --- there is nothing else in it to hold still, so nothing else
   is worth mixing in. What it does with vars and nodes attached is
   [Clock discipline](clock_discipline.md).

   Two readings live inside, not one. `current` is what the world has
   settled on, the reading a node stamps itself with when it recomputes.
   `next` is what the writes since then have reserved for whichever
   recompute comes to pay for them. `Clock.reserve` takes it;
   `Clock.settle` settles onto it.

   Neither is an observation. There is no way to look at this clock
   without moving it, so both are named for what they do rather than
   for the reading they hand back.

   The clock is not part of the API. `Cache.Private.clock` is how these
   tests reach one, there being no other way to make one, and no reason
   for a caller to want to. *)

let print_stamp s = print_dyn (Cache.Private.Clock.Stamp.to_dyn s)

(* @mdexp

   ## Readings

   A reading is abstract --- deliberately, so it cannot be mistaken for
   an unrelated `int` --- and carries exactly what a comparison needs:
   `zero` to start from, `equal`, and `>` for "a later reading than".

   `zero` is where every var and node starts, and it is what a fresh
   clock reads: *)

let%expect_test "Clock: zero, equal, and later-than" =
  (* @mdexp.code *)
  let clock = Cache.Private.clock (Cache.create ()) in
  require_equal
    (module Cache.Private.Clock.Stamp)
    (Cache.Private.Clock.settle clock)
    Cache.Private.Clock.Stamp.zero;
  (* @mdexp

     `>` orders two readings. A reading reserved off that clock is later
     than the zero it was reserved from, and no reading is later than
     itself: *)
  (* @mdexp.code *)
  let reserved = Cache.Private.Clock.reserve clock in
  let ( > ) = Cache.Private.Clock.Stamp.( > ) in
  Printf.printf
    "%b %b %b\n"
    (reserved > Cache.Private.Clock.Stamp.zero)
    (Cache.Private.Clock.Stamp.zero > reserved)
    (reserved > reserved);
  [%expect {| true false false |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## One reading for a whole phase

   `Clock.reserve` is what a write calls to say which reading it is
   announcing itself by. It does not hand out one reading per call: it
   takes one, and every write until something recomputes is announced by
   that same one.

   Called twice over on a fresh clock, with nothing settled in between,
   it yields the same reading both times: *)

let%expect_test "Clock: a run of writes shares one reading" =
  (* @mdexp.code *)
  let clock = Cache.Private.clock (Cache.create ()) in
  print_stamp (Cache.Private.Clock.reserve clock);
  print_stamp (Cache.Private.Clock.reserve clock);
  [%expect
    {|
    1
    1
    |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   That is not economy for its own sake. Two writes with no recompute
   between them are two writes nothing in the graph is in a position to
   tell apart --- no node looked, so no node recorded a reading it could
   later compare against. A recompute is what creates that possibility.

   What it amounts to is a phase: every write between two recomputes
   carries one logical time, the way every write between two
   stabilizations carries one stabilization number in Jane Street's
   incremental. There is no stabilization pass here to draw the
   boundary; `settle` draws it, at the moment a node actually asks.

   ## Settling closes the reading off

   `Clock.settle` is what a node calls when it is about to stamp
   itself. It commits to whatever was reserved --- and the reservation after that
   has to be a fresh one, because the reading just settled on is now one
   a node may have recorded and may later compare against.

   Two reservations, a settle, then a third reservation: *)

let%expect_test "Clock: settling closes a reading off" =
  (* @mdexp.code *)
  let clock = Cache.Private.clock (Cache.create ()) in
  print_stamp (Cache.Private.Clock.reserve clock);
  print_stamp (Cache.Private.Clock.reserve clock);
  print_stamp (Cache.Private.Clock.settle clock);
  print_stamp (Cache.Private.Clock.reserve clock);
  [%expect
    {|
    1
    1
    1
    2
    |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## Settling is idempotent

   `settle` commits once and then keeps answering the same. That is what
   lets a single read stamp every node it recomputes with one reading,
   rather than walking the clock forward node by node --- and it is why
   `refresh` can call it per node without first asking whether it needs
   to: *)

let%expect_test "Clock: settling twice settles once" =
  (* @mdexp.code *)
  let clock = Cache.Private.clock (Cache.create ()) in
  print_stamp (Cache.Private.Clock.reserve clock);
  print_stamp (Cache.Private.Clock.settle clock);
  print_stamp (Cache.Private.Clock.settle clock);
  [%expect
    {|
    1
    1
    1
    |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   ## A phase, step by step

   The two operations together, across several phases: `reserve` is
   what a write calls, `settle` what a recomputing node calls. Each line
   shows what that call returned.

   Three writes in the first phase cost one reading between them, not
   three. Settling then closes reading 1, so the write after it reserves
   reading 2 --- and two settles in a row are one settle: *)

let%expect_test "Clock: reserving and settling, across phases" =
  (* @mdexp.code *)
  let clock = Cache.Private.clock (Cache.create ()) in
  let step name f =
    Printf.printf "%-7s -> " name;
    print_stamp (f clock)
  in
  let reserve () = step "reserve" Cache.Private.Clock.reserve in
  let settle () = step "settle" Cache.Private.Clock.settle in
  reserve ();
  reserve ();
  reserve ();
  settle ();
  reserve ();
  settle ();
  settle ();
  reserve ();
  [%expect
    {|
    reserve -> 1
    reserve -> 1
    reserve -> 1
    settle  -> 1
    reserve -> 2
    settle  -> 2
    settle  -> 2
    reserve -> 3
    |}];
  (* @mdexp.end *)
  ()
;;

(* @mdexp

   What makes the repeated `reserve` idempotent is which reading it
   takes the successor of: `current`, not `next`. `current` does not
   move until a `settle`, so each write in a phase recomputes the *same*
   reading from the same unmoved base, rather than walking one further
   along each time. Taking the successor of `next` instead would put
   back exactly the per-write cost the second reading exists to
   avoid. *)
