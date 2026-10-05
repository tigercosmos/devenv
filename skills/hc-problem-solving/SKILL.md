---
name: hc-problem-solving
description: Frame and solve complex or ambiguous problems with a small, source-traceable set of Minerva cognitive tools. Use for consequential decisions, competing explanations, research design, optimization, or interacting systems; skip routine factual answers and straightforward execution.
---

# HC Problem Solving

Use Habits of Mind and Foundational Concepts (HCs) as a reasoning router
and operator library. Solve the user's problem; keep the framework
invisible unless its structure helps the user.

Scale the workflow to the task. A simple factual question needs a direct
answer, usually without loading any operators or constructing a problem model.
Do not force every request through seven phases or all four competencies.

## Source contract

The baseline is Minerva's public 2017 Degree Learning Objectives.
The [registry](hc_registry.yaml) distinguishes verified official labels from
derived AI operators. See [references](references.md) for provenance and limits.

Minerva defines habits as mental skills triggered automatically with practice.
Foundational concepts are broadly applicable knowledge that typically requires deliberation
(2017 DLOs, p. 3).

This skill maps habits to brief cognitive checks and concepts to deliberately selected tools.
Preserve the source's H/C classification when verified.

Use `runtime_role: check` for a brief triggered audit;
use `runtime_role: tool` for a deliberate analytical artifact.
Expand a check into a plan when its result materially changes the decision.
These runtime roles describe AI use, rather than official classifications.

Derived operators have no official hashtag claim. Registry operations are AI
adaptations, including those attached to official labels.

## 1. Frame the actual problem

For a non-trivial task, identify the surface question, underlying problem,
desired outcome, success criteria, known facts, unknowns, assumptions,
constraints, and stakeholders. Keep this model compact; omit irrelevant fields.

Check whether answering the surface question achieves the desired outcome. Treat a
preferred solution as a candidate, rather than proof of the problem's shape. Respect the
user's explicit goals, constraints, and authorization. If a missing fact changes the
decision, ask one focused question or give a conditional answer. Continue useful work
that does not depend on the missing fact.

## 2. Classify and retrieve candidates

Use multiple problem labels where necessary. These routes suggest candidates;
they do not prescribe mandatory bundles. Read only relevant operator records.

| Label | Candidate operators |
|---|---|
| factual | Usually none; `source_quality` if verification or disagreement matters |
| explanatory | `induction`, `deduction`, `model_types`, `evidence_vs_inference` |
| diagnostic | `right_problem`, `decomposition`, `variables`, `multiple_causes` |
| causal | `correlation_causation`, `variables`, `research_design` |
| prediction | `model_types`, `probability`, `sensitivity_analysis` |
| decision | `goals`, `cost_benefit`, `risk_uncertainty`, `alternative_generation` |
| design | `right_problem`, `constraints`, `decomposition`, `iterative_design`, `multimodal_design` |
| optimization | `goals`, `variables`, `constraints`, `optimization` |
| research | `testability`, `research_design`, `variables`, `statistics` |
| strategy | `right_problem`, `cost_benefit`, `alternative_generation`, `system_boundaries` |
| negotiation | `negotiation`, `batna`, `constraints`, `cost_benefit` |
| complex_system | `system_boundaries`, `levels_of_analysis`, `emergence`, `network` |
| quantitative | `estimation`, `statistics`, `probability`, `variables` |
| communication | `audience_design`, `composition`, `multimodal_design` |
| ethical | `ethical_framing`, `ethical_conflicts`, `goals`, `cost_benefit` |

Adjust candidates using the actual problem characteristics:

- Weak evidence or high uncertainty: consider `evidence_vs_inference`,
  `assumption_check`, `source_quality`, or `testability`.
- High stakes or costly commitment: consider `risk_uncertainty`,
  `sensitivity_analysis`, or `decision_tree`.
- Multiple stakeholders: consider `cost_benefit`, `negotiation`, or
  `group_dynamics` if interests, authority, or incentives affect the result.
- Quantitative claims: consider `estimation` or `statistics`.
- Causal claims: consider `correlation_causation` and `variables`.
- A proposed mechanism conflicts with known constraints: consider `plausibility`
  to check its necessary premises before accepting the explanation.
- Feedback or cross-level effects: consider `system_boundaries`,
  `levels_of_analysis`, or `multiple_causes`.
- A favored option or false binary: consider `alternative_generation`
  or `bias_check`.
- Transfer from a known solution: consider `analogy`; check where the analogy breaks.
- Dynamic interactions or numerical search: consider `simulation` or `algorithms`
  when a model or procedure can resolve the decision.
- Different abilities or motivations: consider `differences` when task assignment
  or collaboration depends on them.
- Influence or adoption: consider `persuasion` when message framing or incentives matter.

The registry groups are `problem_framing`, `evidence`, `logic`,
`quantitative_reasoning`, `causal_reasoning`, `decision_making`,
`problem_solving`, `research_methods`, `complex_systems`, `communication`,
`interaction`, and `ethics`.

With Python and PyYAML available, retrieve only selected records:

```sh
python3 scripts/hc.py show right_problem constraints cost_benefit
```

Run from this skill directory; use `python` on Windows where appropriate.
`list` prints a compact operator index. Without these tools, locate the
selected YAML keys and read their complete records with the available file reader.
Do not load the entire registry or examples for a trivial question.
Read [examples](hc_examples.yaml) only when an application is unclear.

## 3. Select a small set

Evaluate candidates by relevance, expected information gain, decision impact,
non-redundancy, and analysis cost. Prefer an operator that resolves a specific
uncertainty or changes an option's feasibility or ranking.

Use these targets as guidance, not quotas:

- Simple problem: 0–3 operators.
- Moderately complex problem: 3–5 operators.
- Complex decision or system problem: 4–7 operators.

Add more only when a distinct unresolved issue justifies the extra cost.
Do not select an operator through keyword overlap alone.
For each selection, identify the question it answers and the artifact it produces.
Drop an operator if neither affects the analysis.

Avoid duplicates: `assumption_check` prioritizes premises;
`sensitivity_analysis` tests how changes affect conclusions.
`decomposition` separates work; `system_boundaries` tracks external interactions.
`plausibility` checks mechanisms; `estimation` checks numerical scale.
Use both members of a pair only when both distinct outputs matter.

`right_problem` checks the problem framing; `goals` resolves competing values
or success criteria. `bias_check` detects selective judgment; `cost_benefit`
excludes sunk costs from future comparisons. Do not select both by default.

## 4. Apply operators as concrete actions

Use each selected record's `operation` and `expected_output`.
Produce bounded analytical artifacts: constraints, variable roles, evidence,
assumptions, causal comparisons, alternatives, or reversal thresholds.
Naming an HC without such a contribution does not count as application.

For example, constraints separate hard, soft, negotiable, conflicting, and
derived limits. Variables separate outputs, inputs, controls, possible
confounders, and latent factors. Risk analysis separates supported risk
estimates from poorly characterized uncertainty.

Do not fabricate measurements, sources, numerical probabilities, or precision.
Use conditional scenarios when evidence is insufficient.
For estimated effects, distinguish causal attribution from practical importance.
State the decision threshold or the evidence needed to choose one.
An operator's suggestion to study, simulate, or prototype does not authorize
external actions, implementation, or spending beyond the user's request.

## 5. Compare credible alternatives when appropriate

For decision, design, optimization, or strategy tasks, compare viable alternatives
before committing. Include the status quo when feasible and a distinct
mechanism or staged option. Respect explicit restrictions on the option space.

Evaluate benefits, costs, constraints, risks, assumptions, and expected
consequences using shared decision criteria.
Remove a dominated option only when comparable evidence supports dominance.
Record stakeholder conflicts rather than hiding them in an aggregate score.
Skip alternative generation when it cannot improve the requested answer.

## 6. Synthesize an answer

Integrate the operator outputs around the actual problem and decisive evidence.
Lead with the best-supported recommendation or explanation.
Include the assumptions, trade-offs, uncertainty, or next evidence that the
user needs to interpret or act on the result.
Avoid a fixed output template when a shorter answer suffices.

Normally omit HC names and phase headings.
Expose compact structure when the user requests it, when teaching the framework,
or when a decomposition materially helps a complex decision.
When the user requests an HC list, show only the selected operators and their
observable contributions. Distinguish official labels from derived names.
Provide concise explanations or artifacts, never unrestricted private reasoning traces.

## 7. Run one compact final audit

Check only applicable items:

- Does this answer solve the actual problem?
- Are facts, assumptions, and inferences distinguishable?
- Is a material claim unsupported or a major constraint missing?
- Did the first proposed solution crowd out a credible alternative?
- Did association become an unjustified causal claim?
- Is an important stakeholder, interaction, or level of analysis missing?
- Is numerical precision justified?
- Which assumption most affects the conclusion?
- What evidence would change the answer?

Revise only material weaknesses, then answer. Do not restart an endless reflection loop.
