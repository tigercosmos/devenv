# Sources and operator provenance

This skill adapts Minerva cognitive tools into a compact reasoning library.
Its baseline is the public **2017 Degree Learning Objectives (DLOs)**.
The registry represents 11 verified named HCs and 33 derived AI operators.
It covers all four competencies without claiming exhaustive curriculum coverage.

## Primary sources and historical scope

| ID | Source | Version and inspected locations | Use |
|---|---|---|---|
| `dlo2017` | [Extraordinary Student Achievement](https://www.minerva.edu/public/media/enrollment-center/Minerva-Student-Achievement-2017.pdf) | Printed 2017; p. 3 definitions and inclusion criteria; pp. 4–8 DLOs | Baseline objectives for routing and derived operators |
| `intro2017` | [An Introduction to Habits of Mind and Foundational Concepts](https://www.minerva.edu/public/media/enrollment-center/Minerva-HCs-Intro.pdf) | No printed edition date; PDF creation metadata: 2017-03-10; pp. 2–4 overview; pp. 5–17 examples | Verified hashtags and explicit H/C classifications |
| `book2017` | Kosslyn and Nelson, editors, [Building the Intentional University](https://mitpress.mit.edu/9780262037150/building-the-intentional-university/) | MIT Press, 2017; ISBN 9780262037150 | Bibliographic context; full chapter text unavailable in this review |
| `updates2022` | [Academic Updates: HC Changes and Course Preparation](https://community.minerva.edu/news/895234) | 2022-08-23, HC Changes paragraph | Minor paragraph and rubric revisions; explicitly no deletions, renames, mergers, or new HCs that year |
| `application2023` | [NASA Space Apps project interview](https://www.minerva.edu/blog/minerva-university-team-wins-nasa-space-apps-challenge-in-mountain-view/) | 2023-11-21, HC application answer | Later use of `#rightproblem` and `#analogy`; no H/C markers |
| `application2026` | [Gavin Lee interview](https://www.minerva.edu/blog/the-operating-system-between-you-and-ai-a-conversation-with-m21-gavin-lee/) | 2026-03-25, budget-authority anecdote | An application example, not validated effectiveness or a new baseline |

All page references use printed page numbers, which match PDF page positions for the two
baseline documents. Bullet numbers restart within each named section. The registry
stores the downloaded PDFs' SHA-256 digests. The inspection date is 2026-10-05; the
metadata timestamp is not a claimed publication date.

Source verification on 2026-10-05 used Poppler `pdftotext` 26.02.0.
Bullet counting depends on its layout output; other versions can require review.

The introduction explicitly describes a changing set with more than 100 HCs. It provides
selected examples rather than a complete list. The achievement report provides broader
objectives but omits hashtags and individual H/C types. The 2022 update reports minor
paragraph and rubric revisions without deletions, renames, mergers, or additions that year.
It does not establish a complete current list. This package makes no claim about the
present curriculum's exact HC count.

The MIT Press listing and Oxford Academic edition records confirm:

- Stephen M. Kosslyn, chapter 2, **Practical Knowledge**, pp. 19–44:
  [chapter record](https://academic.oup.com/mit-press-scholarship-online/book/17355/chapter/174814127).
- **Appendix A: Habits of Mind and Foundational Concepts**, pp. 379–388:
  [appendix record](https://academic.oup.com/mit-press-scholarship-online/book/17355/chapter/174828729).

The access layer did not provide their full text. These records establish
locations, not verified appendix definitions. No registry label or H/C classification
relies on reconstructing that restricted material. The public Minerva PDFs provide the
operational source basis.

## Official HC, derived operator, and alias

An **official HC** has a verified source label and an explicit H/C marker.
`official_name` preserves the exact hashtag; `type` preserves `habit` or `concept`.
The corresponding `operation` is an AI adaptation, not an official definition or rubric.

A **derived AI operator** implements reasoning supported by identified official
objectives. Its `type` is `derived`, and its `official_name` is null. `derived_from`
links to source-objective records with document, section, page, and bullet range. Those
records' `summary` values are implementation paraphrases, not official names. This
conservative distinction also covers single-objective adaptations when the baseline does
not verify their official label or type.

The 2023 interview names `#rightproblem` and
`#analogy`, but provides no H/C markers. Their implementations retain `derived` status
under this baseline; that status does not assert that the hashtags are unofficial.

An **alias** is a local retrieval synonym for an implementation operator. Aliases in
this version identify implementation synonyms or grouped subtopics. They do not
claim an official historical rename, merger, or hashtag. For example, `opportunity_cost`
points to `cost_benefit`; it is not asserted as an official HC label.

Historical names remain distinct unless a primary source establishes equivalence. For
example, the introduction verifies `#negotiate`; this package does not silently replace
it with `#negotiation`. The introduction explicitly classifies these examples:
`#utility` is a habit, and `#constraints` is a foundational concept in the inspected
introduction.

## Verified named HCs

| Implementation | Official label | Source classification | Introduction page |
|---|---|---|---|
| `estimation` | `#estimation` | Habit | 5 |
| `induction` | `#induction` | Concept | 6 |
| `cost_benefit` | `#utility` | Habit | 7 |
| `model_types` | `#modeltypes` | Concept | 9 |
| `constraints` | `#constraints` | Concept | 10 |
| `iterative_design` | `#designthinking` | Habit | 11 |
| `composition` | `#composition` | Habit | 13 |
| `multimodal_design` | `#multimodaldesign` | Habit | 14 |
| `negotiation` | `#negotiate` | Habit | 15 |
| `differences` | `#differences` | Habit | 16 |
| `ethical_framing` | `#ethicalframing` | Concept | 17 |

The remaining 33 implementation records are explicitly derived.
Their complete provenance is in `source_objectives` and each record's `derived_from`.

## Registry schema and runtime loading

The registry uses YAML mappings with `schema_version`, `baseline`, `sources`,
`source_objectives`, and `groups` at the top level. Each group contains records keyed by
`implementation_name`. Group membership supplies the category; the retrieval helper
exposes it as `category`. Categories and competency placement are implementation choices
based on the source objectives.

Every record contains purpose, problem labels, triggers, avoidance conditions,
questions, concrete operations, expected output, anti-patterns, related operators, and
optional example links. `runtime_role` distinguishes an AI check from a deliberate tool.
Related operators are candidate links, not mandatory dependency expansion.
Official records can contain `supporting_objectives` for additional objectives used by
their AI operations. These references do not change the verified H/C classification.
`show` includes those objectives alongside the official source.

Source-objective records use narrow bullet ranges where possible. A shared range
can support multiple operations; it does not establish equivalence between them.
`derivation_note` identifies extensions where the implementation differs from source
terminology, including boundary artifacts and decision sensitivity analysis.

The repository uses uppercase `SKILL.md` with YAML frontmatter. Both installers discover
that filename and link the complete skill directory. The installers need no change
or duplicate entrypoint. Nearby skills establish no shared registry or eval format, so
these resources use ordinary YAML, Markdown, and a portable Python helper.

The skill system loads supporting files on demand. `scripts/hc.py show` reads the
registry locally but returns only selected records and their provenance, keeping
unrelated operators outside the model context. The helper needs Python 3.9+ and PyYAML;
normal operation can instead use direct file reads. `list` prints an operator index by group.
The skill needs no graph indexing or external service.

## Grouping and omissions

These are implementation groupings, not claims that Minerva merged official HCs.

| Implementation treatment | Baseline locations | Reason |
|---|---|---|
| `right_problem` also covers gap analysis | p. 5, Analyzing Problems, bullets 1–2 | The current-to-desired comparison is an AI adaptation of gap identification and problem characterization |
| `deduction` includes fallacy checks | p. 4, Evaluating Justifications, bullets 4 and 6 | One validity check avoids duplicate logical audits |
| `statistics` covers distributions, summaries, intervals, associations, regression, and both significance meanings | p. 4, Analyzing Data, bullets 2–7 | Descriptive association belongs here; causal identification remains separate |
| `cost_benefit` includes opportunity cost, sunk-cost exclusion, and time horizon | p. 5, Analyzing Decisions, bullets 3 and 7–8; introduction p. 7 | These refine one future-consequence comparison |
| `research_design` covers experiment, observation, survey/interview, case, sampling, controls, and replication | p. 6, Applying Research Methods, bullets 1–7; p. 5, Facilitating Discovery, bullets 1–2; p. 4, Analyzing Data, bullet 7 | Study validity, theory-guided design, and practical effect importance form one study plan |
| `algorithms` includes heuristic choices | p. 6, Solving Problems, bullets 3 and 5–6 | Distinguish computation cost and guarantees in one procedural record |
| `audience_design` covers thesis, argument organization, tone, professionalism, and medium | pp. 6–7, communication sections | Communication activates when it affects comprehension or action |
| `group_dynamics` covers leadership, power, position assessment, conformity, organizational effects, self-awareness, emotional intelligence, and responsibility | p. 8, Working With Others, bullets 1–3 and 5–9 | Individual differences in bullet 4 retain their separate verified record |
| `persuasion` covers choice architecture, incentives, and cognitive/emotional appeals | p. 7, Negotiating and Persuading, bullets 4–8; p. 8, Resolving Ethical Problems, bullet 1 | Influence mechanisms include an explicit fairness check |
| `multimodal_design` also covers data presentation | Introduction p. 14; p. 5, Facilitating Discovery, bullet 4 | Perception principles support both product cues and data visualization |
| No standalone learning-technique operator | p. 6, Solving Problems, bullet 4 | Learning pedagogy is outside the primary problem-solving router |
| No standalone literary or auditory interpretation operator | p. 6, Using Language, bullets 7–8; p. 7, Using Nonverbal Communication, bullets 3–5 | Specialized expressive interpretation requires more domain guidance |
| No standalone game-theory or attractor operator | p. 5, Analyzing Problems, bullet 4; p. 7, systems, bullet 6 | Specialist analysis can use models and sensitivity; no unverified formal procedure is implied |
| No standalone pseudoscience or listening operator | p. 4, Evaluating Claims, bullets 5 and 1 | These objectives are outside the selected registry; general evidence checks do not claim their full coverage |
| No standalone text-engagement or scientific-method evaluation operator | p. 4, Evaluating Claims, bullets 2 and 6 | The library focuses on specific inference and study-design operations |
| No standalone contextual-work interpretation operator | p. 4, Evaluating Justifications, bullet 3 | The printed objective is truncated; the library does not reconstruct its missing text |

`system_boundaries` adds boundary, interface, and feedback artifacts to decomposition
and interaction objectives. Those artifact names are implementation choices.
`sensitivity_analysis` combines risk, simulation, optimization, and dynamical sensitivity
objectives. Decision thresholds are not an official synonym for dynamical sensitivity.

The registry represents all 11 named examples in the introduction.
The broader DLO curriculum is intentionally selective; unused objectives do not
activate merely to increase coverage or satisfy a competency quota.

## Remaining source limits

The full book chapter and appendix remain unverified due to access restrictions. The
introduction's publication date and correspondence to a precise curriculum edition
remain uncertain. Eleven DLO objectives correspond to the verified introduction examples.
Labels and H/C types for the remaining objectives are unverified in this package.

Two printed bullets end mid-parenthesis: Evaluating Justifications bullet 3 and
Analyzing Problems bullet 1. Their missing text is not reconstructed.
Current rubrics and any later official equivalence mappings require
their own primary-source review. This skill is an AI adaptation, not Minerva's
assessment rubric or an endorsed curriculum.
