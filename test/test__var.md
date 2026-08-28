# Var

A var is the mutable leaf everything else is ultimately derived from.
It holds a value, remembers the clock reading of its last write, and
knows which nodes are watching it right now.

Reading one with `Var.peek` records nothing: it is a plain field
access, and the reader does not become dependent on the var. Depending
on a var means watching it --- see [Node](test__node.md).

## create

Creating a var is not a write. It does not advance the clock, and the
var starts at `Stamp.zero` --- the reading that means "never
written".

That holds however busy the cache already is. A var created long after
other vars have been written still starts at zero, rather than at the
clock's current reading: `create` never looks at the clock, only `set`
does.

Nothing about recomputation depends on that. A watch node learns its
var moved by being *told* --- `set` walks the var's watchers and marks
them --- and `refresh` never reads a var's stamp at all. What the zero
buys is an answer to a question someone can ask: the stamp is zero
exactly when the var has never been written, where stamping "now" at
creation would leave never-written and written-on-creation
indistinguishable.

## set

`set` replaces the value and advances the shared clock by one; that
new reading becomes the var's stamp. Two writes, two readings: 1 then
2.

The clock is shared; the stamps are not. Writing one var moves the
clock, which every var in the cache can see, but leaves every other
var's own stamp exactly where it was. That is what lets a node compare
its parent's stamp against its own last look and conclude nothing
relevant happened, even though the cache as a whole has moved on.

## Writing from inside a computation is refused

A node's `f` must not write a var. The write would invalidate whatever
is watching that var --- possibly including the very node that is
part-way through its own refresh --- and the update would be dropped
silently, leaving a node holding a value it should have recomputed.

Rather than let that happen quietly, `set` raises `Invalid_argument`
when a computation is in progress. The failed refresh leaves nothing
wedged: writes from outside work as before, and the node recomputes
the next time it is read (raising again, `f` being unchanged).

## Reading a node from inside a computation is allowed

A nested read tells nothing to anybody, so unlike a write it does not
raise. It also records nothing: the outer node does not become
dependent on what it read, exactly as `Var.peek` would not make it
dependent on a var. It will not be recomputed when that value changes,
and will happily go on serving the answer it computed from it.

This is worth stating because the read *works*, and gives the right
answer at the time. Nothing is broken --- the dependency simply was
never declared. Building the node with `map2` over both parents is
what declares it.
