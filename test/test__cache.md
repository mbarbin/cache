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

## The clock handed back is the live one

`Cache.clock` returns the clock that `Var.set` itself advances, not a
copy or a snapshot of it. Ticking it by hand and then writing a var
makes that visible: the var's stamp comes out as the *second*
reading, because the manual tick already consumed the first. Had
`clock` returned a side channel of its own, the write would have
stamped the var with 1.
