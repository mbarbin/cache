(lang dune 3.20)

(name pulicomv)

(generate_opam_files)

(license ISC)

(authors "Mathieu Barbin")

(maintainers "Mathieu Barbin <opensource@mbarbin.org>")

(source
 (github mbarbin/cache))

(implicit_transitive_deps false)

;; nofunc-htbl/nofunc-map/nofunc-set aren't released to any opam
;; repository yet, so `dune build --workspace=dune-workspace.5.X`
;; (which locks against the repositories in that workspace's own
;; lock_dir, not this machine's local opam switch) can't otherwise
;; find them. One pin covers all three, since they all live in the
;; same nofunc-keyed repo; a dune-project-level pin (unlike a
;; dune-workspace one) applies automatically to every lock_dir, so it
;; doesn't need repeating in each dune-workspace.5.X file.
(pin
 (url "git+https://github.com/mbarbin/nofunc-keyed.git")
 (package
  (name nofunc-htbl))
 (package
  (name nofunc-map))
 (package
  (name nofunc-set)))

(package
 (name pulicomv)
 (synopsis "Pull-based incremental computation over mutable vars")
 (depends
  (ocaml
   (>= 5.2))
  (dyn
   (>= 3.20))
  nofunc-htbl
  nofunc-set
  nofunc-map
  (ordering
   (>= 3.20))))

(package
 (name pulicomv-tests)
 (synopsis "Tests for pulicomv")
 (depends
  (ocaml
   (>= 5.2))
  (pulicomv
   (= :version))
  (dyn
   (>= 3.20))
  nofunc-htbl
  nofunc-set
  nofunc-map
  (ordering
   (>= 3.20))
  (ppx_expect
   (>= v0.17))))

(package
 (name pulicomv-dev)
 (synopsis "Package to regroup dev targets, documentation, and more")
 (allow_empty)
 (depends
  (ocaml
   (>= 5.2))
  (ocamlformat
   (= 0.29.0))
  (bisect_ppx
   (>= 2.8.3))
  (odoc
   (>= 2.0.0))
  (ppx_expect
   (>= v0.17))
  (ppx_js_style
   (>= v0.17))
  (pulicomv
   (= :version))
  (pulicomv-tests
   (= :version))))
