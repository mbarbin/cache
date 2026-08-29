(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

module Stamp = struct
  type t = int

  let zero = 0
  let equal = Int.equal
  let ( > ) = Stdlib.( > )
  let to_dyn = Dyn.int

  (* Not exposed in the [.mli]: only {!Clock.reserve} gets to mint a
     reading nothing has used yet. Named [succ] rather than [next] so it
     doesn't echo the [next] field, which holds a reading rather than
     computing one. *)
  let succ t = t + 1
end

(* Two readings rather than one. [current] is what the world has settled
   on: the reading a node stamps itself with when it recomputes. [next]
   is the reading the writes since then have reserved for whatever
   recompute comes to pay for them — equal to [current] when nothing is
   outstanding, one past it when something is.

   What that buys is a run of writes with no recompute between them
   sharing a single reading instead of consuming one each. {!reserve}
   takes one the first time and hands the same one back to every write
   after that; {!settle} is what commits to it, and is called
   exactly when a node is about to stamp itself. Naming it for the
   transition rather than for the reading it returns is deliberate:
   there is no way to look at this clock without moving it, so an
   observational name would be an invitation to perturb the very thing
   the caller meant to measure.

   That is also what keeps the sharing safe. A recompute between two
   writes moves [current] up, which makes the second write's {!reserve}
   take a fresh reading rather than share the first's — and a
   recompute is the only way a node can have recorded a [checked_at] in
   between, so it is precisely the event that requires two writes to be
   told apart. Absent one, nothing in the graph is in a position to
   compare them, and one reading covers both.

   Both operations are idempotent, which is what lets each be called
   without first asking whether it is needed: {!reserve} twice over
   takes one reading, {!settle} twice over commits once.

   What this amounts to is a phase: every write between two recomputes
   shares one logical time, the way every write between two
   stabilizations shares Jane Street's incremental's stabilization
   number. There is no stabilization pass here to draw that boundary —
   {!settle} draws it instead, at the moment a node actually asks — but
   the shape a caller reasons about is the same one, and it is the
   shape real traffic tends to have: a burst of writes, then reads.

   It also makes readings a good deal harder to run out of. [Stamp.t] is
   an [int], which under js_of_ocaml is 32 bits wide, so the readings a
   long-lived cache can hand out are a finite resource. One per phase
   rather than one per write ties how fast that resource goes to how
   often the program *alternates* between writing and recomputing — not
   to how much it does of either. A burst of writes costs one reading
   however long the burst runs, and reads on their own cost nothing at
   all: they reserve nothing, and settling an already-settled clock
   writes [current] the reading it already holds. It takes a write
   followed by a recompute to spend one.

   Running the range out anyway is not handled, and deliberately not: a
   wrapped reading would compare as *earlier* than the ones before it,
   so nodes would quietly stop recomputing rather than fail in any way
   a caller could catch — which is worth knowing, and still not worth
   guarding, because reaching it takes on the order of two billion
   write-then-recompute alternations in the life of one cache. A
   program that could get there wants a [Stamp.t] wider than an [int],
   not a check on every write. *)
type t =
  { mutable current : Stamp.t
  ; mutable next : Stamp.t
  }

let create () = { current = Stamp.zero; next = Stamp.zero }

(* Settles on whatever the writes since the last recompute reserved, and
   returns it. The commit is the point, not a side effect of a lookup:
   were this to hand back [next] while leaving [current] behind, the very
   next {!reserve} would still find [next] ahead of [current], hand that
   same reading to the write it is announcing, and leave the node that
   had just stamped itself with it unable to tell that write from the one
   before. Committing here is what closes a reading off.

   Unguarded, because [next] is never behind [current]: the only two
   things that write either field are this and {!reserve}, and they leave
   the two equal and one apart respectively. So the assignment either
   commits a reservation that was really outstanding, or writes
   [current] the value it already holds. *)
let settle t =
  t.current <- t.next;
  t.current
;;

(* Reserves the reading this write — and every write up to the next
   recompute — will be known by.

   Unguarded too, and here that is the whole trick: note which field
   the successor is taken of. [current], not [next]. [current] does not
   move until {!settle}, so every write in a phase recomputes the *same*
   reading from the same unmoved base rather than walking one further
   along each time — the assignment stays idempotent for exactly as
   long as the phase lasts, which is exactly as long as it needs to.

   [Stamp.succ t.next] would break that, and is the one edit to guard
   against reaching for: consecutive writes would each consume a
   reading again, which is what this clock did before it had a second
   field and the whole of what the second field is for. *)
let reserve t =
  t.next <- Stamp.succ t.current;
  t.next
;;
