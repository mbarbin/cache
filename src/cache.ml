(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import
open Types

type t = cache

let create () : t = { clock = Clock.create (); refreshing = false }

module Node = Node

module Var = struct
  include Var

  (* [var.ml] does depend on [Node] (for {!Node.Private.invalidate} and
     {!Node.Private.assert_not_refreshing_exn}, both of which {!Var.set}
     calls) — but only at the value level; [var.mli] never mentions
     [Node] itself, and
     {!Node.Private.of_var} — what actually builds a node from a var — is
     no primitive of [Var]'s own, so [watch] is assembled here instead,
     at the one place that already has both in hand. *)
  let watch = Node.Private.of_var
end

module Computation = Computation

module Private = struct
  module Clock = Clock

  let clock (t : t) = t.clock
  let node_stamp = Node.stamp
  let var_stamp = Var.stamp
end
