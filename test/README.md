# Pulicomv Test Suite

This book is the **internal test reference** for pulicomv. It is generated
from OCaml expect tests via [mdexp](https://github.com/mbarbin/mdexp), and is
meant to be browsed alongside the source code.

The chapters are written by Mathieu Barbin together with Claude Opus 5 and
Claude Sonnet 5, in the collaboration described in
[AI-DECLARATION.md](https://github.com/mbarbin/cache/blob/main/AI-DECLARATION.md).

## Who is this for?

The audience is **developers and agents working on the library** --- not
people using it. The user-facing documentation is the odoc interface of
`Cache`, which deliberately stays short and says what the operations
guarantee. This book is where the reasoning behind those guarantees, and the
evidence for them, is allowed to be long.

## Why a book?

Tests accumulate an excruciating level of detail: edge cases, invariants that
only show up at depth, and behaviours that are easy to break without noticing
because nothing names them. Presenting them as a structured book makes that
detail navigable --- a chapter can be skimmed to understand what a module
guarantees, then read closely when changing it.

It also gives every claim somewhere to live. When the interface asserts
something ("a key whose child didn't change keeps the binding it already
had"), the chapter that pins it down is where the argument goes, rather than
into the interface, where it would crowd out the contract.

## How it is generated

Each test file is an OCaml module carrying `@mdexp` directives. Running
`mdexp pp` on the source extracts the prose --- and, where asked, the code
--- into the Markdown you are reading. The sources are compiled and their
snapshots checked on every build, so the book cannot drift from the
implementation: if a behaviour changes, the test fails before the prose has a
chance to become a lie.

## Rules for adding a chapter

**Every chapter opens with a single `#` title and says what it is about.**
The reader arriving from the table of contents has no other context.

**Sections are `##` per operation or behaviour**, using `###` underneath when
one operation needs several tests. Order them the way a reader meets the
module, not the order the tests were written in.

**The prose is Markdown, not odoc.** Write `` `Var.set` ``, not `[Var.set]`.
Link to another chapter by its file name: `[Node](test__node.md)`. Anything
outside `test/` is outside the book, so link to it by its full URL on GitHub
rather than by a relative path that only resolves in the source tree.

**Narration must stand on its own.** By default the book shows no code, so a
paragraph saying "the second call returns the same value" is worthless ---
say which call, and what makes it the same. Read the generated `.md` on its
own before committing it; if it only makes sense next to the source, it is
not finished.

**Ordinary comments stay ordinary.** A remark about why the code is written
the way it is --- an `Sys.opaque_identity` to defeat sharing, a hashtable
kept so the test can reach a child --- belongs in a plain `(* ... *)` comment,
read by whoever edits the test. Only what a reader of the book needs goes in
`@mdexp`.

**Register the chapter**, in two places: a pair of rules in `test/dune`
(generate `$FILE.md.gen`, then `diff` it against `$FILE.md` under the
`runtest` alias), and an entry in the right part of
[SUMMARY.md](SUMMARY.md).

## Building

The Markdown files are regenerated, and checked, by:

```bash
dune runtest
```

A chapter whose prose changed shows up as a diff; accept it with `dune
promote`. To browse the book locally:

```bash
cd test && mdbook serve --open
```
