# Cache

A cache is the context that vars and nodes are created in. It holds
the logical clock they all share, and little else. Creating one is
cheap, and two caches never interact: an operation spanning both is
an error rather than something the library reconciles.

`Cache.Private.clock` exposes that clock. It is not part of the API:
a caller never has to consult it, and the two stamp accessors that
would give a reading meaning live behind `Private` too. The tests
need them, to observe when something moved.

## A fresh cache reads zero

Nothing has been written, so the clock is at `Stamp.zero`. Every
stamp in the library is a reading of this one clock, which makes
"zero" mean "no write has happened yet" rather than "no write to this
particular thing".

```ocaml
let cache = Cache.create () in
require_equal
  (module Cache.Private.Clock.Stamp)
  (Cache.Private.Clock.now (Cache.Private.clock cache))
  Cache.Private.Clock.Stamp.zero;
```

## The clock handed back is the live one

`Cache.clock` returns the clock that `Var.set` itself advances, not a
copy or a snapshot of it. Tick it by hand, with no `Var.set` involved
anywhere:

```ocaml
let cache = Cache.create () in
let v = Cache.Var.create cache 1 in
ignore
  (Cache.Private.Clock.tick (Cache.Private.clock cache) : Cache.Private.Clock.Stamp.t);
```

Then write the var once. Its stamp comes out as the *second*
reading, not the first: the manual tick was a real write to the one
clock `set` advances too. Had `clock` handed back a side channel of
its own, this would print 1.

```ocaml
Cache.Var.set v 2;
print_stamp (Cache.Private.var_stamp v);
[%expect {| 2 |}];
```
