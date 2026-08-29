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

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let n = Cache.Var.watch v in
require_equal (module Int) (Cache.Node.value n) 1;
Cache.Var.set v 2;
require_equal (module Int) (Cache.Node.value n) 2;
```

## A unit var used as a signal

A watch node carries the default `phys_equal` cutoff like any other,
and that has a consequence worth knowing before it surprises someone:
a var whose type has essentially one value never *looks* changed. A
`unit Var.t` used as a "something happened" signal is the case in
point --- `()` is physically equal to itself, so every write is
absorbed and nothing downstream ever fires.

Note which node the cutoff has to be disabled on: `watch` builds a
fresh node per call, so the node passed to `map` is the one that must
be kept and set, not a second `watch` of the same var.

```ocaml
let cache = Cache.create () in
let signal = Cache.Var.create cache () in
(* [watch] builds a fresh node each call, so this one has to be kept and
   reused below rather than calling [watch] again — otherwise disabling
   cutoff on a second, independent node wouldn't touch this one. *)
let signal_node = Cache.Var.watch signal in
let calls = ref 0 in
let n =
  Cache.Node.map signal_node ~f:(fun () ->
    incr calls;
    !calls)
in
require_equal (module Int) (Cache.Node.value n) 1;
```

`()` is `phys_equal` to itself, always, so the default cutoff on the
watch node swallows this write and `n` never recomputes:

```ocaml
Cache.Var.set signal ();
require_equal (module Int) (Cache.Node.value n) 1;
```

Disabling that cutoff makes every write count:

```ocaml
Cache.Node.set_cutoff signal_node ~equal:(fun () () -> false);
Cache.Var.set signal ();
require_equal (module Int) (Cache.Node.value n) 2;
```

## map

`map` runs `f` on demand, and only when its parent has actually moved.
Reading twice with no write in between runs `f` once.

This is the shape most of the tests in this book take: a counter
incremented inside `f`, and a check that pins the value and the number
of times `f` has run together, so that "it did not recompute" is
asserted rather than assumed.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let calls = ref 0 in
let n =
  Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
    incr calls;
    x * 10)
in
let check ~value ~calls:expected_calls =
  require_equal (module Int) (Cache.Node.value n) value;
  require_equal (module Int) !calls expected_calls
in
check ~value:10 ~calls:1;
check ~value:10 ~calls:1;
Cache.Var.set v 2;
check ~value:20 ~calls:2;
```

Writes are targeted rather than global: a write to some other var in
the same cache advances the shared clock, but does not make this node
stale. Staleness is decided against the parents a node actually has,
not against the clock.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let unrelated = Cache.Var.create cache "x" in
let calls = ref 0 in
let n =
  Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
    incr calls;
    x * 10)
in
ignore (Cache.Node.value n : int);
Cache.Var.set unrelated "y";
require_equal (module Int) (Cache.Node.value n) 10;
require_equal (module Int) !calls 1;
```

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
the inputs stopped moving. Below, a node reduces an integer to its
parity --- many different integers share one --- and a downstream node
counts how often it runs:

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 5 in
(* Many different [v] map to the same parity: [set_cutoff Int.equal]
   lets [mid] absorb those. *)
let mid = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x mod 2) in
Cache.Node.set_cutoff mid ~equal:Int.equal;
let downstream_calls = ref 0 in
let downstream =
  Cache.Node.map mid ~f:(fun parity ->
    incr downstream_calls;
    parity)
in
ignore (Cache.Node.value downstream : int);
require_equal (module Int) !downstream_calls 1;
```

5 to 7 is still odd. The parity node re-fires its own closure --- it
has to, to find out --- but its cutoff absorbs the result, so
`downstream` never even considers recomputing:

```ocaml
Cache.Var.set v 7;
ignore (Cache.Node.value downstream : int);
require_equal (module Int) !downstream_calls 1;
```

7 to 8 flips the parity, and now the cutoff lets it through:

```ocaml
Cache.Var.set v 8;
require_equal (module Int) (Cache.Node.value downstream) 0;
require_equal (module Int) !downstream_calls 2;
```

### both, and what the default cutoff can absorb

A pair node is not special: it recomputes when a component moves, and
its own cutoff then decides whether that counts. What is worth showing
is where the *default* cutoff runs out.

Two pairs over the same two vars, one left with the default cutoff
and one given a structural `equal`, each with a reader counting how
often it runs:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache "x" in
let b = Cache.Var.create cache "y" in
let default_calls = ref 0 in
let downstream_default =
  Cache.Node.map
    (Cache.Node.both (Cache.Var.watch a) (Cache.Var.watch b))
    ~f:(fun p ->
      incr default_calls;
      p)
in
let custom_calls = ref 0 in
let custom_pair = Cache.Node.both (Cache.Var.watch a) (Cache.Var.watch b) in
Cache.Node.set_cutoff custom_pair ~equal:(fun (a1, b1) (a2, b2) ->
  String.equal a1 a2 && String.equal b1 b2);
let downstream_custom =
  Cache.Node.map custom_pair ~f:(fun p ->
    incr custom_calls;
    p)
in
ignore (Cache.Node.value downstream_default : string * string);
ignore (Cache.Node.value downstream_custom : string * string);
```

Now a freshly allocated string of the same content. `a`'s own watch
node cannot cut it off --- a different block is a different block ---
so both pairs recompute, even though neither pair's *content* has
changed:

```ocaml
Cache.Var.set a (Bytes.to_string (Bytes.of_string "x"));
ignore (Cache.Node.value downstream_default : string * string);
ignore (Cache.Node.value downstream_custom : string * string);
```

The difference is what each pair's cutoff does with that recompute.
`phys_equal` cannot absorb the fresh tuple, so the default pair reports
a change and its reader runs a second time; the structural `equal`
absorbs it, and its reader does not:

```ocaml
require_equal (module Int) !default_calls 2;
require_equal (module Int) !custom_calls 1;
```

None of which is particular to pairing. Any `f` that allocates its
result is in the same position, which is exactly when
`Node.set_cutoff` is worth reaching for.

### The first computation always counts as a change

A cutoff compares a fresh value against the previously cached one, and
on the first computation there is no previous one. So the first
computation counts as a change however permissive the cutoff is ---
even under the `equal` the test installs, which claims nothing ever
changes.

Pinning that down takes some care. What has to be shown is that the
node moved off the stamp it was *built* with and that its `f` really
ran; not that its stamp differs from zero, which would still read as
passing under a clock that never started there. So the clock is
deliberately advanced by an unrelated write before the node exists,
the node records in a ref that it ran, and every assertion is about
the node's own trajectory from its construction onward.

```ocaml
let cache = Cache.create () in
let clock = Cache.Private.clock cache in
let v = Cache.Var.create cache 1 in
(* Somebody else's write, before [n] is built. *)
let unrelated = Cache.Var.create cache "x" in
Cache.Var.set unrelated "y";
let built_at = Cache.Private.Clock.settle clock in
let fired = ref false in
let n =
  Cache.Node.map (Cache.Var.watch v) ~f:(fun x ->
    fired := true;
    x)
in
(* A cutoff that claims nothing ever changes. *)
Cache.Node.set_cutoff n ~equal:(fun _ _ -> true);
Cache.Var.set v 2;
let after_write = Cache.Private.Clock.settle clock in
require_equal (module Bool) (Cache.Private.Clock.Stamp.equal built_at after_write) false;
```

Forcing it: the closure runs, and the stamp becomes a reading `n`
cannot have been carrying before, since it postdates `n`'s
construction.

```ocaml
let first = Cache.Private.node_stamp n in
require_equal (module Bool) !fired true;
require_equal (module Cache.Private.Clock.Stamp) first after_write;
```

Every computation after that one is absorbed. The closure still fires
and the clock still moves; the stamp is what stays put:

```ocaml
fired := false;
Cache.Var.set v 3;
let second = Cache.Private.node_stamp n in
require_equal (module Bool) !fired true;
require_equal (module Cache.Private.Clock.Stamp) second first;
require_equal
  (module Bool)
  (Cache.Private.Clock.Stamp.equal second (Cache.Private.Clock.settle clock))
  false;
```

### phys_equal earns its keep on ordinary code

The default is worth having rather than merely tolerating. An `f` that
hands back one of its own arguments --- a projection, a lookup, a
value passed straight through --- returns the very same block whenever
that argument did not move, so the cutoff fires with no `equal`
written by anybody. Below, a projection over two parents, with a sink
reading it:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache (ref 1) in
let b = Cache.Var.create cache (ref 2) in
let projections = ref 0 in
let proj =
  Cache.Node.map2 (Cache.Var.watch a) (Cache.Var.watch b) ~f:(fun x _y ->
    incr projections;
    x)
in
let sinks = ref 0 in
let sink =
  Cache.Node.map proj ~f:(fun r ->
    incr sinks;
    !r)
in
require_equal (module Int) (Cache.Node.value sink) 1;
require_equal (module Int) !projections 1;
require_equal (module Int) !sinks 1;
```

`b` moves, so the projection re-fires --- and hands back the very same
`a` it had. `phys_equal` sees that, and the sink does not run:

```ocaml
Cache.Var.set b (ref 22);
require_equal (module Int) (Cache.Node.value sink) 1;
require_equal (module Int) !projections 2;
require_equal (module Int) !sinks 1;
```

`a` moves: a real change, all the way down:

```ocaml
Cache.Var.set a (ref 11);
require_equal (module Int) (Cache.Node.value sink) 11;
require_equal (module Int) !projections 3;
require_equal (module Int) !sinks 2;
```

### Sharing a node shares its cutoff

A cutoff is state on a node rather than on whatever reads it. Several
readers can share one node --- the node a single `Var.watch` call
returned, kept and passed around --- and when they do, they share its
cached value and its cutoff along with it. There is no per-reader
view: one cutoff, and it decides what all of them see.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let shared = Cache.Var.watch v in
(* A cutoff that lets nothing through. *)
Cache.Node.set_cutoff shared ~equal:(fun _ _ -> true);
let calls_1 = ref 0 in
let n1 =
  Cache.Node.map shared ~f:(fun x ->
    incr calls_1;
    x)
in
let calls_2 = ref 0 in
let n2 =
  Cache.Node.map shared ~f:(fun x ->
    incr calls_2;
    x)
in
require_equal (module Int) (Cache.Node.value n1) 1;
require_equal (module Int) (Cache.Node.value n2) 1;
require_equal (module Int) !calls_1 1;
require_equal (module Int) !calls_2 1;
```

The var is written, and neither reader hears about it. The second one
never asked for that cutoff; it reads the node the cutoff is on, which
is the whole of what determines what it sees:

```ocaml
Cache.Var.set v 42;
require_equal (module Int) (Cache.Node.value n1) 1;
require_equal (module Int) (Cache.Node.value n2) 1;
require_equal (module Int) !calls_1 1;
require_equal (module Int) !calls_2 1;
```

## const

A node holding a value that never changes. It has no parent, so
nothing can ever make it stale.

```ocaml
let cache = Cache.create () in
let n = Cache.Node.const cache 42 in
require_equal (module Int) (Cache.Node.value n) 42;
```

## Syntax

`let+` and `and+` are `map` and `both` under applicative syntax, for
combining more nodes than the `mapN` family covers. There is no `let*`
--- the graph's shape is fixed where it is written, which is the
trade this library makes.

Over two vars holding 1 and 2:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache 1 in
let b = Cache.Var.create cache 2 in
let open Cache.Node.Syntax in
let n =
  let+ a = Cache.Var.watch a
  and+ b = Cache.Var.watch b in
  a + b
in
require_equal (module Int) (Cache.Node.value n) 3;
```

## Recomputing settles on a reading, it does not mint one

Only a write reserves a reading. A node that recomputes settles on
whatever the writes since the last recompute reserved, rather than
minting one of its own --- and settling is idempotent, so every node
one read recomputes ends up stamped with the same reading.

That is what makes stamp comparison meaningful across the graph: a
reading identifies the run of writes that caused a change, not the
order in which somebody happened to pull the nodes afterwards.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
Cache.Var.set v 2;
```

Two independent nodes, both forced for the first time after that one
write. Each settles on the reading that write reserved rather than
minting one, so they end up sharing it instead of consuming a
reading each:

```ocaml
let n1 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 10) in
let n2 = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 100) in
ignore (Cache.Node.value n1 : int);
ignore (Cache.Node.value n2 : int);
require_equal
  (module Bool)
  (Cache.Private.Clock.Stamp.equal
     (Cache.Private.node_stamp n1)
     (Cache.Private.node_stamp n2))
  true;
```

## watch builds a fresh node every call

Two `Var.watch` calls on the same var are two independent nodes, each
with its own cached value and its own cutoff. Nothing memoizes one
node per var. Sharing is the caller's business: keep whichever call's
result and reuse it.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
require_equal (module Bool) (phys_equal (Cache.Var.watch v) (Cache.Var.watch v)) false;
let shared = Cache.Var.watch v in
require_equal (module Bool) (phys_equal shared shared) true;
```

## Combining across caches is an error

Stamps are only comparable within one clock, so a node combining
parents from two different caches could not decide staleness at all.
Rather than produce a node that quietly gets it wrong, `both` raises
`Invalid_argument` at construction time.

```ocaml
let a = Cache.Var.watch (Cache.Var.create (Cache.create ()) 1) in
let b = Cache.Var.watch (Cache.Var.create (Cache.create ()) 2) in
require_does_raise (fun () : (int * int) Cache.Node.t -> Cache.Node.both a b);
[%expect {| Invalid_argument("Cache.Node: nodes were not built from the same clock") |}];
```

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

The test walks that whole life cycle. `f` mints one var per key,
seeded to ten times the key, and `creates` counts how many times it
was called:

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1; 2; 3 ]) in
(* One [Cache.Var.t] per key, minted by [f] the first time [collect]
   asks for that key and remembered here so the test can mutate an
   individual child later without going through [f] again. *)
let child_vars : (int, int Cache.Var.t) Hashtbl.t = Hashtbl.create (module Int) 16 in
let creates = ref 0 in
let f k =
  incr creates;
  let v = Cache.Var.create cache (k * 10) in
  Hashtbl.set child_vars ~key:k ~data:v;
  Cache.Var.watch v
in
let node = Cache.Node.collect (module Int) ~keys:(Cache.Var.watch keys) ~f in
let print () =
  let map = Cache.Node.value node in
  let pairs =
    List.map (Map.to_list map) ~f:(fun (k, v) -> Printf.sprintf "%d=%d" k v)
  in
  Printf.printf "[%s]\n" (String.concat ~sep:"; " pairs)
in
print ();
[%expect {| [1=10; 2=20; 3=30] |}];
require_equal (module Int) !creates 3;
```

Reading again without any write re-mints nothing:

```ocaml
print ();
[%expect {| [1=10; 2=20; 3=30] |}];
require_equal (module Int) !creates 3;
```

Changing one existing child's own var --- `keys` never moves --- is
picked up without minting anything new. This is the whole point of
`collect` over the coarse "watch one global signal" alternative:

```ocaml
Cache.Var.set (Hashtbl.find_exn child_vars 2) 99;
print ();
[%expect {| [1=10; 2=99; 3=30] |}];
require_equal (module Int) !creates 3;
```

Adding a key mints exactly one new child. The existing three are not
re-minted --- same vars, same values, and `creates` goes to 4 rather
than 7:

```ocaml
Cache.Var.set keys (Set.of_list (module Int) [ 1; 2; 3; 4 ]);
print ();
[%expect {| [1=10; 2=99; 3=30; 4=40] |}];
require_equal (module Int) !creates 4;
```

Removing a key drops it from the result, and from the memo table
behind it:

```ocaml
Cache.Var.set keys (Set.of_list (module Int) [ 1; 3; 4 ]);
print ();
[%expect {| [1=10; 3=30; 4=40] |}];
require_equal (module Int) !creates 4;
```

And a key that comes back gets a fresh child from `f` rather than the
old one resurrected. Key 2 returns holding 20, not the 99 the previous
child for that key had been mutated to:

```ocaml
Cache.Var.set keys (Set.of_list (module Int) [ 1; 2; 3; 4 ]);
print ();
[%expect {| [1=10; 2=20; 3=30; 4=40] |}];
require_equal (module Int) !creates 5;
```

### Unrelated writes leave it alone

The dynamic parent set does not make `collect` promiscuous: a write to
a var it never collected neither re-mints a child nor recomputes
anything downstream.

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1 ]) in
let unrelated = Cache.Var.create cache "x" in
let creates = ref 0 in
let recomputes = ref 0 in
let node =
  Cache.Node.collect
    (module Int)
    ~keys:(Cache.Var.watch keys)
    ~f:(fun k ->
      incr creates;
      Cache.Node.const cache (k * 10))
in
let node =
  Cache.Node.map node ~f:(fun pairs ->
    incr recomputes;
    pairs)
in
ignore (Cache.Node.value node : int Map.M(Int).t);
Cache.Var.set unrelated "y";
ignore (Cache.Node.value node : int Map.M(Int).t);
require_equal (module Int) !creates 1;
require_equal (module Int) !recomputes 1;
```

### A re-fold that changes nothing yields the same map

The interface claims that a key whose child did not change keeps the
binding it already had, physically unchanged. That rests on `collect`
folding its result *onto the previous map* rather than rebuilding one
from empty: an unchanged key is re-added the value already bound to
it, and adding a binding a map already holds returns that same map
rather than a copy of it.

Followed through, a re-fold in which nothing moved produces the
physically same map, which `collect`'s own default cutoff then
absorbs --- so nothing downstream runs at all.

Getting `collect` to re-fold in the first place takes a nudge: the
test writes a freshly allocated set of equal contents, which the
`keys` watch node has no cutoff to absorb, so `collect` is genuinely
asked to look again. It looks, and finds nothing has changed.

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1; 2 ]) in
let node =
  Cache.Node.collect
    (module Int)
    ~keys:(Cache.Var.watch keys)
    ~f:(fun k -> Cache.Node.const cache (k * 10))
in
let downstream = ref 0 in
let sink =
  Cache.Node.map node ~f:(fun map ->
    incr downstream;
    Map.cardinal map)
in
require_equal (module Int) (Cache.Node.value sink) 2;
require_equal (module Int) !downstream 1;
Cache.Var.set keys (Set.of_list (module Int) [ 1; 2 ]);
require_equal (module Int) (Cache.Node.value sink) 2;
require_equal (module Int) !downstream 1;
```

Same elements, built in a different order --- still the same set, so
still the same map:

```ocaml
Cache.Var.set keys (Set.of_list (module Int) [ 2; 1 ]);
require_equal (module Int) (Cache.Node.value sink) 2;
require_equal (module Int) !downstream 1;
```

### Reading one key cuts off when a different key changes

That preserved binding is what makes reading a single key out of a
collection worthwhile. Below, a node extracts key 1 out of the
collection, and a sink reads that:

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1; 2 ]) in
let child_vars : (int, int ref Cache.Var.t) Hashtbl.t =
  Hashtbl.create (module Int) 16
in
let f k =
  let v = Cache.Var.create cache (ref (k * 10)) in
  Hashtbl.set child_vars ~key:k ~data:v;
  Cache.Var.watch v
in
let node = Cache.Node.collect (module Int) ~keys:(Cache.Var.watch keys) ~f in
let extracts = ref 0 in
let one =
  Cache.Node.map node ~f:(fun map ->
    incr extracts;
    Map.find_exn map 1)
in
let sinks = ref 0 in
let sink =
  Cache.Node.map one ~f:(fun r ->
    incr sinks;
    !r)
in
require_equal (module Int) (Cache.Node.value sink) 10;
require_equal (module Int) !extracts 1;
require_equal (module Int) !sinks 1;
```

Key 2 moves. The extracting node has to look again --- the map is a
new one --- and finds key 1 exactly as it left it, so its own cutoff
stops the change there:

```ocaml
Cache.Var.set (Hashtbl.find_exn child_vars 2) (ref 999);
require_equal (module Int) (Cache.Node.value sink) 10;
require_equal (module Int) !extracts 2;
require_equal (module Int) !sinks 1;
```

Key 1 moves: this one has to reach the sink:

```ocaml
Cache.Var.set (Hashtbl.find_exn child_vars 1) (ref 111);
require_equal (module Int) (Cache.Node.value sink) 111;
require_equal (module Int) !extracts 3;
require_equal (module Int) !sinks 2;
```

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
three-node test can express. So, a chain of fifty:

```ocaml
let cache = Cache.create () in
let depth = 50 in
let v = Cache.Var.create cache 0 in
let nodes = Array.make (depth + 1) (Cache.Var.watch v) in
for i = 1 to depth do
  nodes.(i) <- Cache.Node.map nodes.(i - 1) ~f:(fun x -> x + 1)
done;
let top = nodes.(depth) in
require_equal (module Int) (Cache.Node.value top) depth;
```

Write, then pull only the bottom half. The chain is now live up to the
midpoint and marked above it --- the state no shallow test can
reach:

```ocaml
Cache.Var.set v 10;
require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (10 + (depth / 2));
```

A second write cascades into exactly that mixed chain, and stops where
it meets the marks. The nodes it never reached are the already-marked
ones, and they must still recompute when the top is finally pulled:

```ocaml
Cache.Var.set v 100;
require_equal (module Int) (Cache.Node.value top) (100 + depth);
```

Everything is resolved again, and an ordinary write still travels the
whole depth:

```ocaml
Cache.Var.set v 1000;
require_equal (module Int) (Cache.Node.value top) (1000 + depth);
```

Pulling from the middle afterwards changes nothing anywhere:

```ocaml
require_equal (module Int) (Cache.Node.value nodes.(depth / 2)) (1000 + (depth / 2));
require_equal (module Int) (Cache.Node.value top) (1000 + depth);
```
