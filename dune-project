(lang dune 3.16)
(name rbm)

(generate_opam_files true)

(source (github struktured-labs/recursive-bipartite-matching))
(license MIT)
(authors "Carmelo Piccione")
(maintainers "carmelo.piccione@gmail.com")

(package
 (name rbm)
 (synopsis "Recursive bipartite matching distance on game trees")
 (description "Tree distance metric via recursive Hungarian matching, with application to extensive-form game abstraction (poker)")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.16))
  (core (>= v0.17.0))
  (core_unix (>= v0.17.0))
  (ppx_jane (>= v0.17.0))
  (domainslib (>= 0.5.0))))
