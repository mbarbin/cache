# Node

A node is a memoized computation over vars and over other nodes. It
remembers the value it last produced, the clock reading at which that
value last changed, and the reading at which it last checked ---
which, compared against its parents' readings, is what lets it decide
it has nothing to do.

Nothing here computes on a schedule. A node runs when someone reads
it and its parents have moved since it last looked; a node nobody
reads never runs at all.

## watch

`Var.watch` is where a graph starts: a node whose value is a var's
current value. Writing the var and reading the node again yields the
new value.

## A unit var used as a signal

A watch node carries the default `phys_equal` cutoff like any other,
and that has a consequence worth knowing before it surprises someone:
a var whose type has essentially one value never *looks* changed. A
`unit Var.t` used as a "something happened" signal is the case in
point --- `()` is physically equal to itself, so every write is
absorbed and nothing downstream ever fires.

Disabling the cutoff on the watch node makes every write count. Note
which node it has to be disabled on: `watch` builds a fresh node per
call, so the node passed to `map` is the one that must be kept and
set, not a second `watch` of the same var.

## map

`map` runs `f` on demand, and only when its parent has actually moved.
Reading twice with no write in between runs `f` once.

Writes are targeted rather than global: a write to some other var in
the same cache advances the shared clock, but does not make this node
stale. Staleness is decided against the parents a node actually has,
not against the clock.

`map2`, `map3` and the rest of the family get systematic,
per-component coverage of their own rather than one case each here:
see [The mapN family](test__mapn.md).

## Cutoff

A cutoff decides when a recompute counts as a *change*. When the value
a node has just produced is `equal` to the one it was already holding,
its stamp stays put and nothing built on it recomputes --- the node
itself still ran, since running is how it found out.

That distinction is the whole point: work is stopped at the first node
where the value stopped moving, rather than at the first node where
the inputs stopped moving. The test reduces an integer to its parity:
a write taking it from 5 to 7 is absorbed, and one taking it from 7
to 8 is not.

### both, and what the default cutoff can absorb

A pair node is not special: it recomputes when a component moves, and
its own cutoff then decides whether that counts. What is worth showing
is where the *default* cutoff runs out.

The test sets one component to a freshly allocated but equal string.
That component's own `phys_equal` cutoff cannot absorb it --- a different
block is a different block --- so the pair does recompute, and
allocates a new tuple. `phys_equal` cannot absorb that either, and the
change carries on downstream, although nothing anyone would call a
change has occurred. An explicit structural `equal` installed on the
pair stops it there.

None of which is particular to pairing. Any `f` that allocates its
result is in the same position, which is exactly when
`Node.set_cutoff` is worth reaching for.

## const

A node holding a value that never changes. It has no parent, so
nothing can ever make it stale.

## Syntax

`let+` and `and+` are `map` and `both` under applicative syntax, for
combining more nodes than the `mapN` family covers. There is no `let*`
--- the graph's shape is fixed where it is written, which is the
trade this library makes.

## Recomputing reads the clock, it does not tick it

Only a write advances the clock. A node that recomputes stamps itself
with the clock's *current* reading rather than minting a fresh one, so
two independent nodes forced for the first time after the same single
write end up sharing a stamp.

That is what makes stamp comparison meaningful across the graph: a
reading identifies the write that caused a change, not the order in
which somebody happened to pull the nodes afterwards.

## watch builds a fresh node every call

Two `Var.watch` calls on the same var are two independent nodes, each
with its own cached value and its own cutoff. Nothing memoizes one
node per var. Sharing is the caller's business: keep whichever call's
result and reuse it.

## Combining across caches is an error

Stamps are only comparable within one clock, so a node combining
parents from two different caches could not decide staleness at all.
Rather than produce a node that quietly gets it wrong, `both` raises
`Invalid_argument` at construction time.

## collect

`collect` is the one combinator whose parents are not fixed where it
is written. Given a node holding a set of keys and a function `f` from
key to node, it produces a node holding a map from key to value,
tracking however many children the key set currently calls for.

`f` is called the first time a key is seen and the resulting child is
memoized, so a key that stays put is not rebuilt on every look. A key
that leaves is dropped from the memo table and disconnected; if it
later comes back, `f` mints a *fresh* child for it rather than
resurrecting the old one --- which is what a caller wants when a key
reappearing means the thing behind it was recreated, a deleted file
written again under the same name being the motivating case.

The test walks that whole life cycle: reading twice without
rebuilding, changing one existing child without touching the key set,
adding a key, removing a key, and bringing a removed key back to find
its value reset rather than remembered.

### Unrelated writes leave it alone

The dynamic parent set does not make `collect` promiscuous: a write to
a var it never collected neither re-mints a child nor recomputes
anything downstream.

## Deep chains, pulled part-way

Writing is meant to be cheap, and it is kept cheap by a short-circuit:
the marking pass stops as soon as it reaches a node that is already
marked, on the strength of "already marked" implying "everything below
it is marked too, and its edges were already cut". Get that wrong and
a node stays stale-but-unmarked, serving an out-of-date value forever
--- the one failure mode this design has that a full recompute does
not.

The invariant only becomes interesting once a chain is deep enough to
sit half-resolved and half-marked at the same time, which no two- or
three-node test can express. So: a chain of fifty, written to and then
pulled only up to its midpoint, leaving the bottom live and the top
marked. A second write then cascades into exactly that mixed state and
stops where it finds marks; the nodes it did not reach must still
recompute when finally pulled. Then everything is resolved again and
an ordinary write is shown still travelling the full depth.
