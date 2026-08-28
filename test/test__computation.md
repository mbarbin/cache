# Computation

A computation is a node with no var and no node above it. It caches
the result of an `f` that reads state this library cannot see into ---
a file's parsed contents, the answer to a query --- and is marked
stale by an explicit `Computation.invalidate` call rather than by a
write.

It is the escape hatch for leaves that change for reasons the graph
has no way to observe. Everything downstream of it then behaves like
any other part of the graph.

## invalidate marks; the next read recomputes

`invalidate` does not call `f`. It marks the node stale and returns,
leaving the recompute to whoever reads next --- which is the same
discipline `Var.set` follows, and for the same reason: the library
only ever computes what someone asked for.

Two consequences, and the test pins both: invalidating twice between
reads costs one recompute rather than two, and the value `f` finally
returns is the one the state held at *read* time, not the one it held
at either `invalidate`.

## Nodes built on top see the change

`Computation.node` gives the node to compose with, and from there
nothing is special: an invalidated computation makes what was built on
it stale, and a read pulls the change through --- once.

## Invalidating from inside a computation is refused

The same restriction that applies to `Var.set` applies here, for the
same reason: an invalidation issued from inside a running computation
would be lost. It raises `Invalid_argument`, and invalidating from
outside is unaffected afterwards. See
[Var](test__var.md#writing-from-inside-a-computation-is-refused).
