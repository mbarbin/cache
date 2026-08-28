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

## Two kinds of chapter

**Module chapters** cover one source module each. `src/node.ml` is tested by
`test/test__node.ml` and documented by `test__node.md`. The set of them is
fixed by the set of source modules, which is what makes "is every function
tested?" a question with an answer: a function with no section is a gap,
visible as one.

**Concept chapters** cover one *category* each. They are for what no single
module owns --- an invariant several modules uphold together, a failure mode
that only appears when two of them are combined, a rule a reader has to know
before writing any of it. [Invalid uses](invalid_uses.md) is the first: what
happens when a node's `f` writes, or reads something it was not built from.

The two axes are meant to overlap, not to compete. A module chapter states
what an operation guarantees, at the place a reader looks the operation up. A
concept chapter explains a category and works through it end to end. When
both would cover the same ground, the module chapter keeps the contract and
the test that pins it, and the concept chapter links to it rather than
restating it --- `Var.set` raising from inside a computation is documented
under `Var`, and [Invalid uses](invalid_uses.md) links there and spends its
own space on the misuses that *do not* raise.

Both kinds sit flat in `test/`, and the file name is what tells them apart: a
concept chapter is named for its category (`invalid_uses.ml`), while `test__`
is reserved for the module chapters that mirror a source file.

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

**Narration must stand on its own.** The reader has the prose and whatever
the block shows, and nothing else --- not the rest of the file, not the
interface, not the chapter next door. So a paragraph saying "the second call
returns the same value" is worthless: say which call, and what makes it the
same, and name anything the block uses without binding. Read the generated
`.md` on its own before committing it; if it only makes sense with the source
open beside it, it is not finished.

**Ordinary comments stay ordinary.** A remark about why the code is written
the way it is --- an `Sys.opaque_identity` to defeat sharing, a hashtable
kept so the test can reach a child --- belongs in a plain `(* ... *)` comment,
read by whoever edits the test. Only what a reader of the book needs goes in
`@mdexp`.

**Every section backed by a test shows that test**, wrapped in
`@mdexp.code` ... `@mdexp.end` spanning the whole body, so the block stands on
its own without the reader hunting for where `cache` came from. The prose
says what the test establishes and why anyone should care; the block is the
evidence for it, and a section asserting that something recomputed once and
not twice is worth little without the counters in view.

**Interleave prose with the code for a test that walks through several
steps.** `@mdexp.end`, then an `@mdexp` paragraph, then `@mdexp.code` again
resumes the same test, so the book reads as a walkthrough rather than as one
long block with a preamble. A comment inside a test that narrates what the
next few lines establish --- "5 to 7 is still odd", "a key that comes back
gets a fresh child" --- is that paragraph, written in the wrong place; lift it
out. Comments about how the test is built stay where they are.

Prefer this to summarising the walk in the section's opening paragraph. Say
what the section establishes and why it matters there, and let the steps speak
for themselves below.

**A section with no code is a deliberate one.** Chapter introductions, a
section that exists to point at another chapter, a closing section that names
the rule the chapter has been circling, instructions for the next contributor
--- those carry no test and show no code. Everything else does.

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
