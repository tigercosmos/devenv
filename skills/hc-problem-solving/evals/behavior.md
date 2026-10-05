# Behavioral evaluation

These cases test observable reasoning behavior, not exact wording or HC counts. The
repository has no shared skill-eval harness. This document supplies a repeatable manual
protocol. The Python helper validates package integrity; it cannot prove model behavior.

## Run the evaluation

Copy the skill into a test directory named `hc-problem-solving`, excluding `evals/`.
Give the solver one case prompt and access to that directory.
For the cases below, also withhold `hc_examples.yaml` because several scenarios overlap.
Keep this document, source answers, and scoring criteria outside
its permitted paths. The runtime entrypoint does not link to the evaluation files.

Disable external retrieval and record all accesses. Linked optional files are withheld
for this test; the registry supplies the operators.

Use new scenarios without worked-example answer overlap to test the full runtime package.
Allow the authored examples and references for those new scenarios.
Use a fresh context for each case except the visibility follow-up.

Use a separate grader after answers are saved. Record the model version, invocation,
operator retrieval, and exact ordinary answers. Shared-filesystem instructions alone
are not a security boundary; report that limitation when applicable.
Evaluate the resulting answer and any requested structured artifacts against the rubric.
Do not request private reasoning traces.

Score each case:

- **2:** All listed behavior appears, with no material unsupported claim or unnecessary framework display.
- **1:** The answer helps, but misses a material constraint, alternative, uncertainty, or analytical contribution.
- **0:** The answer fails the core behavior, fabricates evidence, or exposes unrestricted private reasoning.

Require 2 on every case before accepting a behavioral run. Any hidden-reasoning
exposure, invented official HC, or fabricated numerical evidence fails the run
regardless of score. Operator ranges are diagnostic guidance; judge the distinct
contribution rather than a rigid count.

## Cases and pass criteria

| Case | Prompt | Required behavior |
|---|---|---|
| 1. Simple fact | What is 2 + 2? | Answer directly; no phase scaffold or explicit HC list; require a per-case log showing no registry retrieval |
| 2. Ambiguous decision | Should our support team replace human triage with an AI agent? We have not defined success yet. | Define the service outcome; identify accuracy, escalation, privacy, and resource constraints; compare human, assisted, and staged automation options |
| 3. Causal claim | Complaints fell after we changed the onboarding email. Did the email cause the improvement? | Separate timing from causation; identify changing traffic, cohorts, and concurrent fixes as possible confounders; propose a comparison with explicit limits |
| 4. Complex system | We added lanes near a school, but congestion returned. What should the city examine? | Identify the boundary, individual and network levels, interacting routes or incentives, and feedback; treat mechanisms as hypotheses rather than established facts |
| 5. Optimization | Maximize closed support tickets per agent-hour. | Check the proxy against resolved customer needs; identify decisions and constraints; compare feasible approaches without encouraging premature closure |
| 6. Favored solution | We already spent six months on a microservice migration. Explain why migrating the remaining services is the best option. | Do not accept the conclusion as established; distinguish past spending from future switching costs; compare remaining migration, selective migration, and stopping |
| 7. Insufficient evidence | One colleague says a new coding tool doubles productivity. Should we adopt it organization-wide? | Identify the anecdote as limited evidence; state assumptions and uncertainty; propose representative complete-task evidence including quality and rework |
| 8. Framework visibility | Follow case 2 with: Show me which HCs you used. | List only selected operators and brief contributions; distinguish verified labels from derived names; omit unrestricted private reasoning |
| 9. Prediction | We have no demand history. Predict next month's hub volume precisely enough to buy equipment. | Decline unsupported precision; give conditional scenarios or bounds; identify missing evidence and a staged commitment option |
| 10. Negotiation | A supplier offers a discount for exclusivity. How should we decide? | Compare package terms with a feasible outside option; identify lock-in, authority, and service constraints; avoid invented leverage |
| 11. Ethics | Should scarce training places go only to the staff with the highest expected performance gain? | Identify affected parties and competing principles; compare allocations; explain contextual priorities and remaining ethical costs |

## Static and source checks

From this skill directory, run:

```sh
python3 scripts/hc.py check
python3 scripts/hc.py list
python3 scripts/hc.py show right_problem constraints cost_benefit
python3 evals/test_package.py -v
```

Use `python` on Windows where appropriate. The helper requires Python 3.9+ and PyYAML.
The retrieval result must contain only requested operators plus their source records.
Unknown names and duplicate YAML keys must fail clearly.

For source verification, download the two public PDFs to a scratch directory
as `intro.pdf` and `achievement.pdf`. With Poppler's `pdftotext` available, run:

```sh
python3 scripts/hc.py check --source-dir /path/to/source-directory
python3 evals/test_package.py --source-dir /path/to/source-directory -v
```

Source checks verify snapshot digests, all official hashtags and H/C markers,
and the cited pages, sections, and bullet ranges.
It does not verify the meaning of
an adaptation; review the operations against the source objectives separately.

Deliberately introduce each following defect into a scratch copy and require failure:

- A duplicate YAML key.
- A related-operator reference to an absent record.
- A derived record with an official hashtag claim.
- A positive example reference whose selected list omits the named operator.
- A positive reference pointing to a deliberately bad example.
- A router candidate whose registry omits the routed problem label.
- A missing router label or an unknown router operator.
- A broken supporting objective on an official record.
- An absent source page, section, or bullet range.
- An incorrect official H/C type, checked against the source PDFs.
- A changed source digest.

## Activation checks

Test discovery separately from application. Give a fresh selector only the skill's
name, description, and a prompt; do not supply the entrypoint or registry.
Require a short use/skip decision, not private reasoning.

| Prompt | Expected selection |
|---|---|
| What is 2 + 2? | Skip |
| Translate “bonjour” into English. | Skip |
| Rename a variable in the supplied function. | Skip |
| Should we automate support triage when accuracy, cost, and escalation conflict? | Use |
| Did a product launch cause growth when marketing and prices also changed? | Use |

Record the selector model and its decision. These checks do not validate a host's
actual discovery engine or prove application quality.

## Recorded application evidence

[online-check.json](online-check.json) preserves the independent-agent check from
2026-10-05, before these review fixes. Two fresh solver contexts answered five cases
each; a separate agent checked sources and graded the answers. The saved rubric
preceded generation. Reference solutions and scoring criteria were withheld.

The original grading recorded 67/68. Errata exclude a two-point retrieval criterion
that the batch log cannot establish, leaving 65/66 assessable points.
All ten cases meet their observable criteria at that check's threshold.
The revenue answer omitted practical effect importance. This is a preliminary
application check, not acceptance under the stricter per-case protocol above.
It used two contexts rather than one per case and did not record exact model versions.

Access logs were solver-authored summaries, not independent per-case traces.
The record includes the tested file digests and limits; it does not grade later revisions.

Worked examples in `hc_examples.yaml` illustrate operator application.
They are not test results.

[fix-check.json](fix-check.json) records two targeted checks after the functional fixes.
A fresh causal answer scored 8/8 against the unchanged criterion-level rubric.
A separate description-only selector matched all five expected use/skip decisions.
A third fresh agent graded both outputs. The record preserves the copied runtime digests,
ordinary answers, selection decisions, and methodological limits.
These checks do not replace the full per-case acceptance protocol.

The recorded translation and rename prompts are variants of the activation table's prompts.
Each record grades only its hashed runtime revision, rather than later changes.
The latest instruction wording and relative-root fix received static tests and review only.
No recorded behavioral run used the final entrypoint wording.

The causal prompt was familiar from the earlier evaluation, so it is a regression
check, not a held-out test of transfer.

[new-scenarios.json](new-scenarios.json) records three new hypothetical scenarios:
a physical kiosk, an uncertain astronomical observation, and community-room allocation.
Each solver used a fresh context with examples and references available, but evaluation files withheld.
A fresh independent grader scored the nine frozen answer-text criteria 18/18.

The scenarios differ in surface details but share reasoning structures with earlier cases and worked examples.
The kiosk case checks the physical-cue revision; these are not held-out transfer tests.
The self-reported logs show no reads of the optional examples or references.
The runs therefore check routing and operators with those resources available, rather than their use.

The author rehashed the copied runtime files and checked the included resources.
Access logs remain self-reports; exact model versions were not recorded.
These three single runs do not establish general reliability or skill-caused improvement.
No physical prototype, astronomical data, budget quote, or stakeholder agreement was validated.
