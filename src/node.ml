(*********************************************************************************)
(*  pulicomv - pull-based incremental computation over mutable vars              *)
(*  SPDX-FileCopyrightText: 2025-2026 Mathieu Barbin <mathieu.barbin@gmail.com>  *)
(*  SPDX-License-Identifier: ISC                                                 *)
(*********************************************************************************)

open! Import

(*_ [t] is [Types.node] — see [types.ml] for the field-by-field layout of
  [t]/[shape]/[packed] and why they and [Var.t] are defined together
  there rather than each in its own file. [refresh] is the one recursive
  function that pattern-matches on [shape] and knows how to recompute
  each kind of node, instead of that logic being reimplemented by hand
  inside each constructor's own closure.

  Two different questions drive a {!refresh}, one cheap and one precise,
  and keeping them apart is what makes a read between two writes nearly
  free:

  - "Might I be stale at all?" is [is_invalidated], a plain bool. A write
    ({!Var.set}) or an external {!Cache.Computation.invalidate} flips it
    on every node currently reachable from it — the whole subgraph, right
    away, via {!invalidate} walking [children] — because at that point
    nothing is known yet about whether any of it will turn out to
    matter. [refresh] short-circuits to the cached value with no shape
    inspected and no parent touched whenever this is [false] — which,
    between writes, is every read: one bool test, however deep the chain
    of parents above it.
  - "Do I *actually* need to recompute?" — once [is_invalidated] says
    "maybe" — is the precise, per-shape comparison: refresh whichever
    parents this node reads (recursively — a parent that's already
    resolved returns just as cheaply, since it went through the same
    two-step check) and compare each one's [stamp] against [checked_at]. This is what keeps a cutoff a few levels up
    still stopping a downstream recompute (see the "cutoff stops a
    downstream recompute" test): [is_invalidated] alone can't tell — it
    was flipped on both the cutoff-absorbing node *and* everything below
    it, eagerly, before either one had a chance to run — but [checked_at]
    can, because it isn't touched at all when a parent's cutoff decides
    nothing really changed.

  [children] is a live edge only while a node is actually resolved (not
  invalidated) and worth telling: {!connect} (re-)adds a node to a
  parent's [children] the moment it finishes checking that parent
  ("refresh reconnects"), and {!invalidate} unconditionally empties a
  node's own [children] the moment it cascades through it ("invalidate
  disconnects") — a node that's currently invalidated is, for exactly as
  long as it stays that way, absent from every parent's [children]. That's
  what keeps this from leaking: a long-lived var or node doesn't hold a
  downstream node alive forever just because it was read once — the very
  next write that reaches it drops the edge, and if nothing else
  references that downstream node, it's collectible from there (bounded
  by "until this parent's next write", not "forever"). A node picks the
  edge back up itself the next time it's actually pulled and resolves —
  nothing needs to do that on its behalf. A var's own [children] is the
  same discipline one level up: it holds real node pointers too (see
  [types.ml]), connected the same way, disconnected in one move by every
  {!Var.set}. *)

open Types

type 'a t = 'a node

module type Key = Types.Key

(* Raised when one of this module's own invariants breaks — a bug here,
   not something a caller could trigger by ordinary API misuse (that's
   [Invalid_argument]'s job, see {!assert_same_cache_exn}). Both raise
   sites below are in fact provably unreachable — see each one — and
   marked [@coverage off] accordingly. *)
exception Invariant_failure of string

(* Only the [Invariant_failure] arm is unreachable from a legitimate
   test, same as the two raise sites below: nothing here raises it
   without one of this file's own invariants having broken first — hence
   [@coverage off] on that arm alone. The fallback arm carries no such
   marker and needs none: this is a global [Printexc] hook, so it sees
   every other exception in the program, and any test that prints one
   exercises it. *)
let () =
  Printexc.register_printer (function
    | Invariant_failure msg -> Some ("Cache.Node: " ^ msg) [@coverage off]
    | _ -> None)
;;

(* Whether [packed] entry [Packed n] refers to the very node [t] itself —
   the identity {!connect}/{!disconnect} need to tell one [packed] apart
   from another, without a synthetic id field: two ['a t]/['b t] values
   can't be compared with [phys_equal] directly when ['a] and ['b] might
   differ (which, existentially, they might — that's the whole reason
   {!packed} exists), so [Obj.repr] erases each to a common type first,
   safely — this only ever feeds [phys_equal], never [Obj.obj], so it
   can't be used to treat one node as if it were another. *)
let same (type a b) (t : a t) (n : b t) = phys_equal (Obj.repr t) (Obj.repr n)

(* [t] might now be stale and, transitively, so might everything currently
   reading from it — flip [is_invalidated] and hand each current child the
   same news, via its own [children] list, which this also empties (the
   "invalidate disconnects" half of the module doc's discipline: a node
   sitting in some parent's [children] only while resolved). The
   [is_invalidated] guard both stops re-walking a diamond twice in one
   cascade and, since a node only ever reappears in [children] by
   reconnecting itself during its own [refresh], is what keeps this
   terminating and each node visited at most once per cascade. Eager and
   unconditional on purpose — see the module doc for why this has to be a
   safe over-approximation rather than trying to decide "really changed"
   here, which would need each node's own cutoff to have already run.

   Written as an explicit worklist, not as a direct recursive descent
   through [List.iter], so the traversal is obviously tail recursive —
   stack usage doesn't grow with how wide or deep the currently-connected
   subgraph is, only [visit_one]/[visit_batch]'s own accumulators do:
   [todo], what's left to visit at the current node's own level, and
   [more], every level still waiting underneath it. [more] is a
   [packed list list], not a [packed list] merged one child at a time —
   [visit_one] conses a whole [children] list onto it in one step rather
   than reversing it into a flat accumulator, so discovering a node's
   children costs exactly one allocation (the cons cell) no matter how
   many there are, not one per child. Neither function needs the
   polymorphic recursion {!refresh} needs — a node's own type doesn't
   matter once it's wrapped. [visit_one] either finds its node already
   invalidated — nothing left to do, its own [children] already empty
   from whichever earlier event marked it — or marks it now and pushes
   its [children] onto [more]; [visit_batch] drains [todo] by handing
   each entry to [visit_one], and once [todo] itself runs dry, pops the
   next level off [more] and keeps going until both are empty. *)
let invalidate (type a) (t : a t) : unit =
  let rec visit_one (Packed t) ~todo ~more =
    if t.is_invalidated
    then visit_batch ~todo ~more
    else (
      t.is_invalidated <- true;
      let children = t.children in
      t.children <- [];
      visit_batch ~todo ~more:(children :: more))
  and visit_batch ~todo ~more =
    match todo with
    | packed :: todo -> visit_one packed ~todo ~more
    | [] ->
      (match more with
       | [] -> ()
       | todo :: more -> visit_batch ~todo ~more)
  in
  visit_one (Packed t) ~todo:[] ~more:[]
;;

let remove_child (type a) (t : a t) children =
  List.filter children ~f:(fun (Packed n) -> not (same t n))
;;

(* [t] currently depends on [parent] and wants to hear about [parent]'s
   next change. [t] may already be in [parent.children] from before this
   same [refresh] (a sibling parent already resolved without moving [t]
   out of *this* parent's list, e.g. [Map2]'s [a] found stale while [b]
   wasn't) — checking first, rather than unconditionally removing any
   existing entry and adding the (possibly unchanged) result, keeps the
   common case — [t] genuinely wasn't there, or was already exactly there
   — to a read-only scan plus at most one new cons cell, instead of an
   [O(\|parent.children\|)] reallocation of the whole list on every single
   [connect] call regardless of whether anything needed to move. [Const]
   never changes, so a node depending on one has nothing to ever be told;
   skipping it there avoids the one case where the edge really would sit
   forever. *)
let connect (type p) (t : _ t) (parent : p t) =
  match parent.shape with
  | Const _ -> ()
  | _ ->
    if not (List.exists parent.children ~f:(fun (Packed n) -> same t n))
    then parent.children <- Packed t :: parent.children
;;

let disconnect (type a p) (t : a t) (parent : p t) =
  parent.children <- remove_child t parent.children
;;

(* The one place recomputation is decided and performed, shared by every
   shape below. [is_invalidated] is the fast path: [false] means [cached]
   already is what a check would produce, so this returns it straight off
   without so much as looking at [shape] — no parent touched, however deep
   the chain above [t]. Only when [is_invalidated] is [true] does this
   look at [shape] at all — refresh whichever parents it reads
   (recursively — a parent found already resolved returns just as
   cheaply), reconnect to each of them via {!connect}, and ask the shape
   for the precise [stale] verdict (or, on the first call, when [cached]
   is still empty, run [compute] regardless). [checked_at] moves to the
   clock's current reading ([Clock.now], read-only — forcing a node is not
   itself a write) whenever [compute] runs, including when this node's own
   [equal] goes on to decide the result doesn't count as a change: without
   that, a parent that moved once would keep testing as past this node on
   every later look, re-firing [f] every time instead of settling. [stamp] — what a *child's own future* [refresh] compares against
   — only follows along when [equal] says the new value isn't the same as
   the old one (always true the first time, there being no old value yet).
   No {!invalidate} call happens here, on [t]'s own [children], to go with
   that: whatever is currently in [children] was already told, transitively,
   by whichever {!Var.set}/{!Cache.Computation.invalidate} made [t] itself
   invalidated in the first place — that cascade doesn't wait for [t] to
   actually be pulled and recomputed the way this comparison does, and by
   the time [t] gets here [children] is empty regardless (see the module
   doc): nothing reconnects to [t] until it's resolved, and [t] isn't yet.
   Either way, [is_invalidated] is cleared: [t] has now been checked as of
   the current state of the world, whatever the verdict was.

   Polymorphic recursion (the [type a.] annotation) is what lets this one
   function call itself at a different type per parent — [Map2]'s two
   parents, say, generally don't share a type with each other or with the
   node being refreshed. *)
let rec refresh : type a. a t -> a * Clock.Stamp.t =
  fun t ->
  if t.is_invalidated
  then (
    let stale, compute =
      match t.shape with
      | Const _ ->
        (* Unreachable, not just unlikely: {!connect} never lets anything
           depend on a [Const] (see there), so nothing is ever in a
           position to {!invalidate} one — [is_invalidated] starts and
           stays [false] for the lifetime of a node built by {!const}.
           Hitting this would mean that invariant broke somewhere else,
           not a case real traffic is expected to exercise — hence
           raising, not returning a value, and coverage off: there's no
           legitimate test that could reach it without first breaking
           something this file is supposed to guarantee. *)
        raise
          (Invariant_failure "Refresh found an invalidated Const node") [@coverage off]
      | Computation f -> true, f
      | Var var ->
        (* Directly on the var's own [children] — no [connect] helper
           needed. [connect]'s dedup exists for a node with *several*
           parents: invalidated via one of them, it can still be sitting
           un-disconnected in another's [children] that never fired, so
           reconnecting to everyone risks a duplicate in that other
           parent's list. [t] here has exactly one parent — this
           [var], full stop, not "at most one node happens to be
           watching [var]" (plenty can be, via separate {!Var.watch}
           calls) — so there's no *other* parent's list it could still be
           stuck in: the only way [t] ever becomes invalidated is
           {!Var.set} on this same [var], which always empties the
           *whole* [var.children] — every current watcher, not just [t]
           — before any of them can run again and try to reconnect. No
           cutoff on [Var] itself either — every [set] moves its [stamp]
           unconditionally (see [var.ml]) — so [is_invalidated] having
           been flipped here already means the var really did move past
           [t.checked_at]; nothing sharper to ask. *)
        var.children <- Packed t :: var.children;
        let value = var.value in
        true, fun () -> value
      | Collect { key_module; keys; f; table } ->
        (* Same generalization [map]/[map2]/[map3] don't cover: however
           many parents there currently are, discovered from [keys] at
           refresh time rather than fixed at construction time. One child
           node per current key, created via [f] on first sight and
           memoized in [table], dropped once its key is no longer in
           [keys]'s current value (so a key that later reappears — a
           file deleted and recreated under the same name, say — gets a
           fresh child node via [f] rather than the stale one from
           before) — and, since [t] no longer reads it,
           explicitly {!disconnect}ed from it too, rather than leaving [t]
           sitting in a now-irrelevant child's [children] until that child
           happens to change again on its own. Staleness folds every
           currently-relevant parent the same way [map3] folds exactly
           three: [keys] itself, plus every child actually in scope this
           round. *)
        let keys_value, keys_stamp = refresh keys in
        connect t keys;
        let keys_changed = Clock.Stamp.(keys_stamp > t.checked_at) in
        if keys_changed
        then
          (* [Set.mem] against [keys_value] directly — no separate scratch
             structure needed here the way a plain [list] would have
             required, [keys_value] already answers "is [k] still live" on
             its own. *)
          Hashtbl.filter_map_inplace table ~f:(fun ~key:k ~data:child ->
            if Set.mem keys_value k
            then Some child
            else (
              disconnect t child;
              None));
        let stale = ref keys_changed in
        (* Built by folding onto the *previous* result, not rebuilt from
           scratch: a key whose child didn't change gets {!Map.add}ed the
           exact same (already-[phys_equal]) value it already had, which
           [Map.add] itself then turns into a no-op that leaves that
           binding — and everything structurally around it — untouched.
           That's what lets a caller depending on just one key's value
           (via a further [map] with its own cutoff) actually skip work
           when a *different* key changes, the fine-grained staleness
           this node already computes otherwise going to waste the moment
           it's flattened into one bulk value every reader has to accept
           as "different" in full. *)
        let previous =
          match t.cached with
          | Some m -> m
          | None ->
            let module Key = (val key_module) in
            Map.empty (module Key)
        in
        let after_removals =
          if not keys_changed
          then previous
          else
            Map.fold previous ~init:previous ~f:(fun ~key ~data:_ acc ->
              if Set.mem keys_value key then acc else Map.remove acc key)
        in
        let map =
          Set.fold keys_value ~init:after_removals ~f:(fun ~elt:k acc ->
            let child =
              match Hashtbl.find table k with
              | Some child -> child
              | None ->
                let child = f k in
                Hashtbl.set table ~key:k ~data:child;
                child
            in
            let value, child_stamp = refresh child in
            connect t child;
            if Clock.Stamp.(child_stamp > t.checked_at) then stale := true;
            Map.add acc ~key:k ~data:value)
        in
        !stale, fun () -> map
      | Map { a; f } ->
        let value_a, stamp_a = refresh a in
        connect t a;
        Clock.Stamp.(stamp_a > t.checked_at), fun () -> f value_a
      | Map2 { a; b; f } ->
        let value_a, stamp_a = refresh a in
        let value_b, stamp_b = refresh b in
        connect t a;
        connect t b;
        ( Clock.Stamp.(stamp_a > t.checked_at || stamp_b > t.checked_at)
        , fun () -> f value_a value_b )
      | Map3 { a; b; c; f } ->
        let value_a, stamp_a = refresh a in
        let value_b, stamp_b = refresh b in
        let value_c, stamp_c = refresh c in
        connect t a;
        connect t b;
        connect t c;
        ( Clock.Stamp.(
            stamp_a > t.checked_at || stamp_b > t.checked_at || stamp_c > t.checked_at)
        , fun () -> f value_a value_b value_c )
    in
    (match t.cached with
     | Some _ when not stale -> ()
     | previous ->
       let value = compute () in
       let now = Clock.now t.cache.clock in
       t.checked_at <- now;
       (match previous with
        | Some previous when t.equal previous value -> ()
        | _ ->
          t.cached <- Some value;
          t.stamp <- now));
    t.is_invalidated <- false);
  match t.cached with
  | Some value -> value, t.stamp
  | None ->
    raise (Invariant_failure "Refresh left an invalidated node uncached") [@coverage off]
;;

(* The one entry point into {!refresh} from outside, and the only place
   [cache.refreshing] is written. Set for the *outermost* call only:
   {!refresh} recurses through parents, and a node reading another node
   from inside its own closure ends up here again too — both are ordinary
   nested reads, and a read tells no one anything, so the flag they find
   already set is left exactly as it is (and, crucially, not cleared on
   the way out of the inner call). What the flag buys is
   {!assert_not_refreshing_exn} below. [Fun.protect] rather than a plain
   sequence: a closure that raises must not leave the whole cache stuck
   in "a refresh is in flight" forever, refusing every subsequent write. *)
let force (type a) (t : a t) : a * Clock.Stamp.t =
  let cache = t.cache in
  if cache.refreshing
  then refresh t
  else (
    cache.refreshing <- true;
    Fun.protect ~finally:(fun () -> cache.refreshing <- false) (fun () -> refresh t))
;;

(* Guards the two ways a caller can tell this world that something
   changed — {!Var.set} and {!Cache.Computation.invalidate} — against
   being called from inside a node's own computation, where the resulting
   cascade would silently lose the update (see [types.ml]'s [refreshing]
   for exactly how). [Invalid_argument], like {!assert_same_cache_exn}:
   an ordinary caller mistake that can genuinely leak out of the library,
   not one of this module's own invariants breaking. *)
let assert_not_refreshing_exn (cache : Types.cache) ~msg =
  if cache.refreshing then invalid_arg msg
;;

let value t = fst (force t)
let stamp t = snd (force t)

(* Shared by every constructor below except {!const}: a fresh node with
   the ordinary "nothing computed yet" bookkeeping, wrapping whichever
   {!shape} the caller built. Starting [is_invalidated] at [true] is what
   makes the very first {!refresh} always look, the same way the previous
   [cached = None] check used to gate it. *)
let make ~cache (shape : 'a shape) : 'a t =
  { cache
  ; is_invalidated = true
  ; stamp = Clock.Stamp.zero
  ; checked_at = Clock.Stamp.zero
  ; cached = None
  ; equal = phys_equal
  ; children = []
  ; shape
  }
;;

let const cache v : 'a t =
  (* Not built via {!make}: [cached] is pre-filled with [v] itself and
     [is_invalidated] starts (and stays) [false], so {!refresh} takes the
     "already resolved" path on every call without ever invoking
     [compute] — [v] is thus, per the {!Cache.Node.const} doc, truly never
     recomputed, and [stamp]/[checked_at] stay at {!Clock.Stamp.zero}
     forever: a constant has nothing to have "changed at". *)
  { cache
  ; is_invalidated = false
  ; stamp = Clock.Stamp.zero
  ; checked_at = Clock.Stamp.zero
  ; cached = Some v
  ; equal = phys_equal
  ; children = []
  ; shape = Const v
  }
;;

let map (a : 'a t) ~(f : 'a -> 'b) : 'b t = make ~cache:a.cache (Map { a; f })

(* An ordinary caller mistake (mixing nodes from two different {!Cache.t}s),
   not one of this module's own invariants — [Invalid_argument], not
   {!Invariant_failure}, since this can genuinely leak out to a caller and
   [Invalid_argument] names what actually happened. *)
let assert_same_cache_exn a b =
  if not (phys_equal a.cache b.cache)
  then invalid_arg "Cache.Node: nodes were not built from the same clock"
;;

let map2 (a : 'a t) (b : 'b t) ~(f : 'a -> 'b -> 'c) : 'c t =
  assert_same_cache_exn a b;
  make ~cache:a.cache (Map2 { a; b; f })
;;

let both (a : 'a t) (b : 'b t) : ('a * 'b) t = map2 a b ~f:(fun a b -> a, b)

let map3 (a : 'a t) (b : 'b t) (c : 'c t) ~(f : 'a -> 'b -> 'c -> 'd) : 'd t =
  assert_same_cache_exn a b;
  assert_same_cache_exn b c;
  make ~cache:a.cache (Map3 { a; b; c; f })
;;

let collect
      (type k cmp)
      (module Key : Types.Key with type t = k and type comparator_witness = cmp)
      ~(keys : (k, cmp) Set.t t)
      ~(f : k -> 'v t)
  : (k, 'v, cmp) Map.t t
  =
  let table : (k, 'v t) Hashtbl.t = Hashtbl.create (module Key) 16 in
  make ~cache:keys.cache (Collect { key_module = (module Key); keys; f; table })
;;

let set_cutoff t ~equal = t.equal <- equal

module Syntax = struct
  (* Kept as [return], not renamed to [const] alongside {!Node.const} above:
     this is the conventional name for a [let+]/[and+] surface's "lift a
     plain value in" operation (cf. [Base]'s [Applicative]/[Let_syntax]),
     so a reader bringing that expectation to [open Cache.Node.Syntax]
     finds what they're looking for under the name they're looking for. *)
  let return = const
  let ( let+ ) t f = map t ~f
  let ( and+ ) a b = both a b
end

module Private = struct
  (* [invalidate] is exposed here too, not just used internally: it's
     [Var.set]'s and [Computation.create]'s own entry point for
     disconnecting/telling watchers (see [var.ml]/[computation.ml]) — the
     same operation either way, whether the trigger is a var write or an
     external {!Cache.Computation.invalidate} call. *)
  let invalidate = invalidate
  let assert_not_refreshing_exn = assert_not_refreshing_exn
  let of_var (var : 'a Types.var) : 'a t = make ~cache:var.cache (Var var)

  (* No real parent to read a stamp from, so staleness is driven entirely
     by [is_invalidated], which only a caller's own {!invalidate} call
     (see [computation.ml], which pairs this with the closure that makes
     that call) ever moves off [false]. Just the node, not a bundle — see
     [types.ml]'s ['a computation] and [computation.ml] for where the
     node and its invalidating closure are actually paired up; this and
     {!of_var} sit next to each other here as the module's two "no real
     parent" leaf constructors, symmetric on purpose. *)
  let computation ~cache ~(f : unit -> 'a) : 'a t = make ~cache (Computation f)
end
