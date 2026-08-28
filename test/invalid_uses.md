# Invalid uses

A node's `f` is meant to be a function of the parents the node was
built from, and nothing else. Two ways of stepping outside that are
worth knowing about, because the library treats them very
differently.

Writing during a computation is **refused**: it raises, loudly, at the
moment it happens. Reading during a computation is **allowed but
untracked**: it does not raise, it returns the right answer, and it
quietly leaves the reading node with a dependency it does not have.

The second is the one to watch. Nothing marks the code as wrong ---
not the type checker, not a runtime check, and not the first test
anyone writes, because the value read is correct the first time. What
goes wrong is what happens *later*.

## What raises

`Var.set` and `Computation.invalidate` both raise `Invalid_argument`
when called from inside a running computation. The update would
otherwise cascade into a node part-way through its own refresh and be
lost there, leaving a node holding a value it should have recomputed
--- with nothing to show that it happened.

Each is covered where its contract lives:
[Var](test__var.md#writing-from-inside-a-computation-is-refused)
and
[Computation](test__computation.md#invalidating-from-inside-a-computation-is-refused).
The rest of this chapter is about the cases that do not raise.

## Reading a var with `peek`

`Var.peek` reads a var's current value directly. It records nothing
--- that is its whole purpose, and it is exactly why it is not called
`value`.

Called from inside a node's `f`, it is a dependency the graph never
hears about. The node below is built from `a` alone and peeks at `b`,
and it computes the right answer to begin with:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache 1 in
let b = Cache.Var.create cache 10 in
let calls = ref 0 in
let n =
  Cache.Node.map (Cache.Var.watch a) ~f:(fun x ->
    incr calls;
    x + Cache.Var.peek b)
in
require_equal (module Int) (Cache.Node.value n) 11;
require_equal (module Int) !calls 1;
```

Now `b` moves. Nothing is stale --- `n` was built from `a` --- so `f`
does not run again, and `n` goes on reporting the sum it computed from
the old `b`:

```ocaml
Cache.Var.set b 20;
require_equal (module Int) (Cache.Node.value n) 11;
require_equal (module Int) !calls 1;
```

Worse than the stale value is what happens next. Write to `a` --- a
var the node *does* depend on --- and it recomputes, picking up the
new `b` on the way. The reading is now up to date, and it was brought
up to date by an unrelated write.

That is the failure mode: not a value that is permanently wrong, but
one whose correctness depends on whether something else happened to
change recently. It will look right in most tests.

The same node again, carried one write further:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache 1 in
let b = Cache.Var.create cache 10 in
let n = Cache.Node.map (Cache.Var.watch a) ~f:(fun x -> x + Cache.Var.peek b) in
require_equal (module Int) (Cache.Node.value n) 11;
Cache.Var.set b 20;
require_equal (module Int) (Cache.Node.value n) 11;
```

A write to `a` is what finally makes `b`'s change visible --- 2 + 20,
picked up on the way past:

```ocaml
Cache.Var.set a 2;
require_equal (module Int) (Cache.Node.value n) 22;
```

## Reading a node with `value`

The same thing, one level up. A nested `Node.value` tells nothing to
anybody, so unlike a write it does not raise; and it records nothing,
so the outer node does not depend on the inner one.

It is worth being explicit that nothing here is broken. The nested
read runs the inner node's own machinery, cutoff and all, and returns
what that node currently holds. The dependency simply was never
declared.

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
let w = Cache.Var.create cache 100 in
let inner = Cache.Node.map (Cache.Var.watch w) ~f:(fun x -> x + 1) in
let outer =
  Cache.Node.map (Cache.Var.watch v) ~f:(fun x -> x + Cache.Node.value inner)
in
require_equal (module Int) (Cache.Node.value outer) 102;
```

Writing `w` is not refused --- the computation is over by now --- but
`outer` was built from `v` alone, so it is not stale and does not run
again:

```ocaml
Cache.Var.set w 200;
require_equal (module Int) (Cache.Node.value outer) 102;
```

A write to what `outer` *does* depend on picks up the new `inner` along
the way, exactly as in the `peek` case:

```ocaml
Cache.Var.set v 2;
require_equal (module Int) (Cache.Node.value outer) 203;
```

## What to do instead

Declare the dependency where the node is built. `map2` over both
parents says what the peeking and the nested-reading versions only
implied, and the graph can then act on it: a write to either parent
makes the node stale, and reading it gives an answer that does not
depend on what else happened to change.

The same node as the first example, built correctly:

```ocaml
let cache = Cache.create () in
let a = Cache.Var.create cache 1 in
let b = Cache.Var.create cache 10 in
let calls = ref 0 in
let n =
  Cache.Node.map2 (Cache.Var.watch a) (Cache.Var.watch b) ~f:(fun x y ->
    incr calls;
    x + y)
in
require_equal (module Int) (Cache.Node.value n) 11;
require_equal (module Int) !calls 1;
```

`b` now counts:

```ocaml
Cache.Var.set b 20;
require_equal (module Int) (Cache.Node.value n) 21;
require_equal (module Int) !calls 2;
```

And so does `a`:

```ocaml
Cache.Var.set a 2;
require_equal (module Int) (Cache.Node.value n) 22;
require_equal (module Int) !calls 3;
```

## How to tell the difference

The rule that separates the two halves of this chapter is not "reads
are fine and writes are not". It is that **the graph only knows about
the parents a node was built from**. Everything a node's `f` reaches
for by any other route --- a var through `peek`, a node through
`value`, a mutable cell of your own, a file --- is invisible to it.

For state the library genuinely cannot see into, that invisibility is
the point, and [Computation](test__computation.md) is the supported
way to have it: an explicit `invalidate` call says "this leaf moved"
in the one vocabulary the graph does understand.
