# License

pulicomv is released under the terms of the `ISC` license.

This notice file contains more details, as well as document the organization of files and headers that relate to licenses.

## License, copyright & notices

- **COPYING.HEADER** contains the copyright and license notices. It is added as a header to every file in the project.

- **LICENSE** contains a copy of the full [ISC license](https://spdx.org/licenses/ISC.html).

- **NOTICE.md** (this file) documents the project licensing.

## A note about highlight.js

`doc/book/shared-theme/highlight.js` is a vendored build of
[highlight.js](https://github.com/highlightjs/highlight.js) `v11.9.0`, released
under `BSD-3-Clause`. It is a custom build including the OCaml grammar, which
the stock mdbook bundle does not carry; it overrides mdbook's own copy so that
the OCaml in the test book is syntax-highlighted.

It is a development-time asset only --- no part of it is linked into, or
distributed with, the `pulicomv` library.

### Notice

highlight.js's original LICENSE is included in this repo at
`third-party-license/highlightjs/LICENSE`, and its copyright and license
notice is retained in the header of the vendored file itself.

## A note about Incremental

pulicomv borrows ideas and terminology from Jane Street's [incremental](https://github.com/janestreet/incremental) project, which is released under `MIT`. We're referring to `incremental` as of version `v0.17.0`.

No code from `incremental` is included in this project: pulicomv is an independent implementation, with deliberately narrower goals (no `bind`, no `stabilize`, recomputation driven by reads). What we did take from `incremental` is its vocabulary and its framing:

- the `Var` / `Node` split, and `Var.watch` as the way to obtain a node reading a var;

- the *cutoff* (`Node.set_cutoff`, defaulting to `phys_equal`), which decides whether a recompute counts as a change for a node's children;

- more broadly, the framing: `incremental` is the reference point this project's README states its own design against.

### Notice

`incremental`'s original LICENSE is included in this repo at `third-party-license/janestreet/incremental/LICENSE.md`.

We're grateful to Jane Street for releasing `incremental` as open source. Note that pulicomv and `incremental` are independent projects with no specific ties: `incremental` may have evolved since the version referenced here, and we make no claims about its current state or future direction. `incremental` remains a fuller and more powerful library to reach for when `bind` is what you need.
