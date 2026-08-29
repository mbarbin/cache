# Clock discipline

Every node below the one that changed decides whether to recompute by
comparing a parent's stamp against the reading at which it itself last
looked. That comparison is only as good as the stamps handed to it,
and putting them there is the job of whoever announced the change:
`Var.set` and `Computation.invalidate`.

The obligation is the same for both, and it is strict. A change has to
land *past* the last look of everything below it, not merely at it. A
stamp equal to a child's own last reading is indistinguishable from no
change at all, and the child will serve its cached value and be right
by its own lights --- there is nothing further down that could catch
it.

`Computation.invalidate` is where that obligation is easiest to
overlook, because a computation has so little of its own to move. A
var has a value to write and a stamp to advance. A computation has
neither, and no parent whose stamp could carry the news either: its
node stamps itself with whatever the clock reads at the moment `f`
re-runs. Unless something advanced the clock in between, that is
precisely the reading the node below it already recorded.

This chapter is the evidence for that obligation, in the arrangements
where it is actually load-bearing. It exists because the invariant was
for a long time held up by a single test: dropping the reading
`Computation.invalidate` reserves used to leave the whole suite green
but for one case.

## Why a direct read proves nothing

Reading `Computation.node` directly performs no stamp comparison at
all. A computation is marked stale by `invalidate` and by nothing
else, and a refresh that finds it marked re-runs `f` without
consulting a stamp anywhere --- which is why
[Computation](test__computation.md#invalidate-marks-the-next-read-recomputes)
passes whether the clock moved or not.

It takes a node *built on top* to notice, that node being the first
thing in the graph with a reading of its own to compare against.
[Computation](test__computation.md#nodes-built-on-top-see-the-change)
covers the one-level case and keeps it. What follows are the
arrangements it does not reach.

## Down a chain

One level below a computation is enough to detect a stamp that did not
move, but it is not enough to show that the change keeps travelling.
Here `comp` reads a `source` the library cannot see into, `mid`
multiplies by ten, and `outer` adds one, each counting its own calls:

```ocaml
let cache = Cache.create () in
let source = ref 1 in
let f_calls = ref 0 in
let mid_calls = ref 0 in
let outer_calls = ref 0 in
let comp =
  Cache.Computation.create cache ~f:(fun () ->
    incr f_calls;
    !source)
in
let mid =
  Cache.Node.map (Cache.Computation.node comp) ~f:(fun x ->
    incr mid_calls;
    x * 10)
in
let outer =
  Cache.Node.map mid ~f:(fun x ->
    incr outer_calls;
    x + 1)
in
let check ~value ~f_calls:expected_f ~mid_calls:expected_mid ~outer_calls:expected_outer
  =
  require_equal (module Int) (Cache.Node.value outer) value;
  require_equal (module Int) !f_calls expected_f;
  require_equal (module Int) !mid_calls expected_mid;
  require_equal (module Int) !outer_calls expected_outer
in
check ~value:11 ~f_calls:1 ~mid_calls:1 ~outer_calls:1;
```

The source moves and the computation is invalidated. Both levels below
run again, and `outer` reports the new figure rather than the one it
had cached:

```ocaml
source := 2;
Cache.Computation.invalidate comp;
check ~value:21 ~f_calls:2 ~mid_calls:2 ~outer_calls:2;
```

Reading again, with nothing invalidated in between, runs none of the
three:

```ocaml
check ~value:21 ~f_calls:2 ~mid_calls:2 ~outer_calls:2;
```

Two invalidations with no read between them are one recompute, not
two. `f` sees the state as it stands at the read --- 4, not the 3 that
was current at the first `invalidate` --- and each level runs once:

```ocaml
source := 3;
Cache.Computation.invalidate comp;
source := 4;
Cache.Computation.invalidate comp;
check ~value:41 ~f_calls:3 ~mid_calls:3 ~outer_calls:3;
```

## Alongside a var write

A computation and a var share one clock, and a node can be built from
both at once. That is the arrangement in which one kind of write could
quietly stand in for the other --- a var write advancing the clock far
enough that a downstream node recomputes and picks up an invalidation
that had not, on its own, moved anything.

### Neither event masks the other

`n` reads the computation and the var together. Each is moved on its
own, then both between the same pair of reads, with the call count
checked after every step:

```ocaml
let cache = Cache.create () in
let source = ref 1 in
let comp = Cache.Computation.create cache ~f:(fun () -> !source) in
let v = Cache.Var.create cache 100 in
let calls = ref 0 in
let n =
  Cache.Node.map2 (Cache.Computation.node comp) (Cache.Var.watch v) ~f:(fun c x ->
    incr calls;
    c + x)
in
let check ~value ~calls:expected_calls =
  require_equal (module Int) (Cache.Node.value n) value;
  require_equal (module Int) !calls expected_calls
in
check ~value:101 ~calls:1;
```

The var alone:

```ocaml
Cache.Var.set v 200;
check ~value:201 ~calls:2;
```

The computation alone:

```ocaml
source := 2;
Cache.Computation.invalidate comp;
check ~value:202 ~calls:3;
```

And both, between one read and the next. They collapse into a single
recompute that carries both changes --- 3 from the computation, 300
from the var --- rather than one recompute each:

```ocaml
source := 3;
Cache.Computation.invalidate comp;
Cache.Var.set v 300;
check ~value:303 ~calls:4;
```

With nothing moved since, the next read runs nothing:

```ocaml
check ~value:303 ~calls:4;
```

### A write elsewhere neither triggers nor substitutes

The previous test always read between the two kinds of write, so each
had to carry its own change. This one takes the two halves apart.

`unrelated` is a var nobody watches. Writing it advances the shared
clock and reaches no node at all, which makes it exactly the thing
that must not be mistaken for news: it must not make a node
recompute, and it must not be what makes an earlier invalidation
visible either.

First that it triggers nothing. `n` below is built from the
computation alone, and the write leaves it untouched:

```ocaml
let cache = Cache.create () in
let source = ref 1 in
let f_calls = ref 0 in
let comp =
  Cache.Computation.create cache ~f:(fun () ->
    incr f_calls;
    !source)
in
let unrelated = Cache.Var.create cache 0 in
let calls = ref 0 in
let n =
  Cache.Node.map (Cache.Computation.node comp) ~f:(fun x ->
    incr calls;
    x * 10)
in
require_equal (module Int) (Cache.Node.value n) 10;
require_equal (module Int) !f_calls 1;
require_equal (module Int) !calls 1;
Cache.Var.set unrelated 1;
require_equal (module Int) (Cache.Node.value n) 10;
require_equal (module Int) !f_calls 1;
require_equal (module Int) !calls 1;
```

Now the other half. The computation is invalidated and *not* read;
then `unrelated` is written, advancing the clock past the point the
invalidation reached. The read that follows must recompute because of
the invalidation, and would have had to whether the unrelated write
had happened or not:

```ocaml
source := 2;
Cache.Computation.invalidate comp;
Cache.Var.set unrelated 2;
require_equal (module Int) (Cache.Node.value n) 20;
require_equal (module Int) !f_calls 2;
require_equal (module Int) !calls 2;
```

## Two computations in one cache

Computations in the same cache share a clock but nothing else.
Invalidating one has to reach everything below that one and nothing
below the other --- a distinction the clock cannot draw on its own,
since a single reading is all either of them gets.

Two computations, each with a node of its own beneath it:

```ocaml
let cache = Cache.create () in
let a_source = ref 1 in
let b_source = ref 100 in
let comp_a = Cache.Computation.create cache ~f:(fun () -> !a_source) in
let comp_b = Cache.Computation.create cache ~f:(fun () -> !b_source) in
let a_calls = ref 0 in
let b_calls = ref 0 in
let na =
  Cache.Node.map (Cache.Computation.node comp_a) ~f:(fun x ->
    incr a_calls;
    x * 10)
in
let nb =
  Cache.Node.map (Cache.Computation.node comp_b) ~f:(fun x ->
    incr b_calls;
    x * 10)
in
let check ~a ~b ~a_calls:expected_a ~b_calls:expected_b =
  require_equal (module Int) (Cache.Node.value na) a;
  require_equal (module Int) (Cache.Node.value nb) b;
  require_equal (module Int) !a_calls expected_a;
  require_equal (module Int) !b_calls expected_b
in
check ~a:10 ~b:1000 ~a_calls:1 ~b_calls:1;
```

Only `comp_a` is invalidated. `nb` is read in the same breath and does
not run: the clock has moved, but nothing told `nb` about it:

```ocaml
a_source := 2;
Cache.Computation.invalidate comp_a;
check ~a:20 ~b:1000 ~a_calls:2 ~b_calls:1;
```

And the other way round, `comp_b` alone:

```ocaml
b_source := 200;
Cache.Computation.invalidate comp_b;
check ~a:20 ~b:2000 ~a_calls:2 ~b_calls:2;
```

Both, one after the other with no read in between. Sharing whatever
reading the clock happens to be at costs neither of them its own
change:

```ocaml
a_source := 3;
b_source := 300;
Cache.Computation.invalidate comp_a;
Cache.Computation.invalidate comp_b;
check ~a:30 ~b:3000 ~a_calls:3 ~b_calls:3;
```

## Under collect

`collect` compares stamps in two places rather than one: the `keys`
node's, to decide whether the membership moved, and each current
child's, to decide whether that key's value did. A computation can sit
in either position, and each comparison has to be shown separately.

The key module handed to `collect` throughout is the test prelude's
`Int`, which carries everything `collect` asks of a key type ---
`equal` and `hash` for its memo table, `compare` and a
`comparator_witness` for the key sets it reads. See
[Test helpers](test__import.md#int-as-a-key-module).

### A child computation reaches the collection

Each key gets a source cell the library cannot see into and a
computation reading it. Both are remembered per key, so the test can
move one key's leaf without going through `f` again:

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1; 2 ]) in
let sources : (int, int ref) Hashtbl.t = Hashtbl.create (module Int) 16 in
let comps : (int, int Cache.Computation.t) Hashtbl.t = Hashtbl.create (module Int) 16 in
let f k =
  let source = ref (k * 10) in
  let comp = Cache.Computation.create cache ~f:(fun () -> !source) in
  Hashtbl.set sources ~key:k ~data:source;
  Hashtbl.set comps ~key:k ~data:comp;
  Cache.Computation.node comp
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
[%expect {| [1=10; 2=20] |}];
```

Key 2's source moves and its computation is invalidated. `keys` itself
never moved, so the collection is asked to look again purely on the
strength of that child's stamp:

```ocaml
Hashtbl.find_exn sources 2 := 999;
Cache.Computation.invalidate (Hashtbl.find_exn comps 2);
print ();
[%expect {| [1=10; 2=999] |}];
```

### The per-key cutoff still holds

Reaching the collection is not the same as reaching everything below
it. A binding whose child did not move is re-added the value it
already had, and `collect`'s result keeps it physically unchanged ---
which is what lets a node reading a single key out of the map cut off
when a *different* key's computation was the one invalidated.

Here `one` extracts key 1 out of the collection, and `sink` doubles
whatever `one` produced:

```ocaml
let cache = Cache.create () in
let keys = Cache.Var.create cache (Set.of_list (module Int) [ 1; 2 ]) in
let sources : (int, int ref) Hashtbl.t = Hashtbl.create (module Int) 16 in
let comps : (int, int Cache.Computation.t) Hashtbl.t = Hashtbl.create (module Int) 16 in
let f k =
  let source = ref (k * 10) in
  let comp = Cache.Computation.create cache ~f:(fun () -> !source) in
  Hashtbl.set sources ~key:k ~data:source;
  Hashtbl.set comps ~key:k ~data:comp;
  Cache.Computation.node comp
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
  Cache.Node.map one ~f:(fun v ->
    incr sinks;
    v * 2)
in
let check ~value ~extracts:expected_extracts ~sinks:expected_sinks =
  require_equal (module Int) (Cache.Node.value sink) value;
  require_equal (module Int) !extracts expected_extracts;
  require_equal (module Int) !sinks expected_sinks
in
check ~value:20 ~extracts:1 ~sinks:1;
```

Key 2's computation is invalidated. The map is a new one, so `one` has
to look again --- and finds key 1 bound to exactly what it was, so
`sink` does not run:

```ocaml
Hashtbl.find_exn sources 2 := 999;
Cache.Computation.invalidate (Hashtbl.find_exn comps 2);
check ~value:20 ~extracts:2 ~sinks:1;
```

Key 1's computation is invalidated: this one has to reach the sink:

```ocaml
Hashtbl.find_exn sources 1 := 111;
Cache.Computation.invalidate (Hashtbl.find_exn comps 1);
check ~value:222 ~extracts:3 ~sinks:2;
```

### When the key set itself is a computation

The other stamp `collect` consults belongs to `keys`, and a
computation can supply it: a set of keys derived from state the
library cannot see into --- the entries currently in a directory,
say. An invalidation then has to move the membership, which is a
different comparison from the per-child one above, and the only one
that can add or drop a child.

`creates` counts the children minted, so that the walk shows the memo
table being maintained across the change and not rebuilt:

```ocaml
let cache = Cache.create () in
let key_source = ref (Set.of_list (module Int) [ 1; 2 ]) in
let comp_keys = Cache.Computation.create cache ~f:(fun () -> !key_source) in
let creates = ref 0 in
let f k =
  incr creates;
  Cache.Node.const cache (k * 10)
in
let node =
  Cache.Node.collect (module Int) ~keys:(Cache.Computation.node comp_keys) ~f
in
let print () =
  let map = Cache.Node.value node in
  let pairs =
    List.map (Map.to_list map) ~f:(fun (k, v) -> Printf.sprintf "%d=%d" k v)
  in
  Printf.printf "[%s]\n" (String.concat ~sep:"; " pairs)
in
print ();
[%expect {| [1=10; 2=20] |}];
require_equal (module Int) !creates 2;
```

A key is added to the set behind the computation. The membership
change is seen, and exactly one new child is minted --- keys 1 and 2
are found in the memo table rather than rebuilt:

```ocaml
key_source := Set.of_list (module Int) [ 1; 2; 3 ];
Cache.Computation.invalidate comp_keys;
print ();
[%expect {| [1=10; 2=20; 3=30] |}];
require_equal (module Int) !creates 3;
```

And keys are dropped the same way, minting nothing:

```ocaml
key_source := Set.of_list (module Int) [ 1 ];
Cache.Computation.invalidate comp_keys;
print ();
[%expect {| [1=10] |}];
require_equal (module Int) !creates 3;
```

## The cutoff still decides

Everything above is about a change reaching far enough. The converse
matters just as much: `invalidate` says "look again", not "something
changed", and the node's own cutoff is what turns the one into the
other. An invalidation that leads to a value the cutoff considers
unchanged must stop there.

The computation below returns a freshly allocated string every time it
runs, so the default `phys_equal` cutoff would let every invalidation
through; `String.equal` is set on its node instead, and `downstream`
counts what gets past it:

```ocaml
let cache = Cache.create () in
let source = ref "hello" in
let f_calls = ref 0 in
let comp =
  Cache.Computation.create cache ~f:(fun () ->
    incr f_calls;
    String.uppercase_ascii !source)
in
Cache.Node.set_cutoff (Cache.Computation.node comp) ~equal:String.equal;
let d_calls = ref 0 in
let downstream =
  Cache.Node.map (Cache.Computation.node comp) ~f:(fun s ->
    incr d_calls;
    String.length s)
in
let check ~value ~f_calls:expected_f ~d_calls:expected_d =
  require_equal (module Int) (Cache.Node.value downstream) value;
  require_equal (module Int) !f_calls expected_f;
  require_equal (module Int) !d_calls expected_d
in
check ~value:5 ~f_calls:1 ~d_calls:1;
```

An invalidation with the source left alone. `f` runs --- the
invalidation was believed, and there is no way to know the answer
without asking --- but the string it produces is `String.equal` to the
one cached, so nothing below runs:

```ocaml
Cache.Computation.invalidate comp;
check ~value:5 ~f_calls:2 ~d_calls:1;
```

A real change, and the same machinery lets it through:

```ocaml
source := "goodbye";
Cache.Computation.invalidate comp;
check ~value:7 ~f_calls:3 ~d_calls:2;
```

## A read that recomputes nothing costs nothing

Only two things move the clock: a write reserving a reading, and a
node settling onto one as it stamps itself. The second half is worth
stating on its own, because `Node.value` is easy to read as "the
operation that advances the clock" and it is not one. A node already
resolved returns its cached value without settling anything, so a
phase an outstanding write opened stays open across it.

That is what keeps a burst of writes cheap while readers are pulling
at other parts of the graph in between. Below, `v` and `w` are
unrelated vars with a node each, and `w`'s node is read while a write
to `v` is outstanding.

Nothing here can ask the clock what it holds: `Clock.settle` is the
only way to see a reading, and asking would close the very phase
under test. So the evidence is indirect --- the stamp the *next*
write to `v` comes out with. A reading that had moved would mean the
intervening read closed the phase.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let n = Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x * 10) in
let w = Cache.Var.create cache "x" in
let w_calls = ref 0 in
let m =
  Cache.Node.map (Cache.Var.watch w) ~f:(fun s ->
    incr w_calls;
    s ^ "!")
in
require_equal (module Int) (Cache.Node.value n) 10;
require_equal (module String) (Cache.Node.value m) "x!";
require_equal (module Int) !w_calls 1;
```

A write to `v`, and a read that does recompute: that settles the
phase the write opened. The write after it therefore opens a new one,
whose reading the test holds on to:

```ocaml
Cache.Var.set v 2;
require_equal (module Int) (Cache.Node.value n) 20;
Cache.Var.set v 3;
let reserved = Cache.Private.var_stamp v in
```

Now the read under test. `m` was resolved and nothing has invalidated
it --- `w` was never written --- so its `f` does not run:

```ocaml
require_equal (module String) (Cache.Node.value m) "x!";
require_equal (module Int) !w_calls 1;
```

The phase is therefore still open, and the next write to `v` is
announced by the reading already reserved rather than by a fresh
one:

```ocaml
Cache.Var.set v 4;
require_equal (module Cache.Private.Clock.Stamp) (Cache.Private.var_stamp v) reserved;
```

And the contrast, to show the assertion above can fail: a read that
*does* recompute settles the phase, so the write after that one is
announced by a reading of its own:

```ocaml
require_equal (module Int) (Cache.Node.value n) 40;
Cache.Var.set v 5;
require_equal
  (module Bool)
  (Cache.Private.Clock.Stamp.equal (Cache.Private.var_stamp v) reserved)
  false;
```

## The rule

A write's job is not to move the clock. It is to leave every node
below it able to tell, by comparison alone, that something happened
since it last looked --- and to leave every node not below it unable
to tell anything of the sort.

That is what the clock buys, and what any other arrangement of stamps
would have to buy in its place. It is also the whole of what the
clock owes: two writes with nothing pulled between them are two
writes no node is in a position to compare, so they share one
reading, and the rule is satisfied by fewer readings than there were
writes --- see
[Clock](test__clock.md#next-reserves-one-reading-for-a-whole-phase).

The tests in this chapter are written against that rule rather than
against the mechanism: they say which reads must recompute and which
must not, and none of them names a stamp. Where a reading *is* pinned
to a literal number, it is because the number is the point --- and
those tests live in [Cache](test__cache.md) and
[Var](test__var.md), where the clock is the subject rather than the
mechanism.
