# Stage 6 — Validation and Profiling of Clusters (v1.2)

> **Implementation status (2026-11-07):** implemented in `scripts/validate_stage6.R` (tests: `tests/test_validate.R`).
> - Restart stability (V01): from the saved Stage 4 diagnostics, with label-aligned parameter differences. Partition-level ARI requires an approved replay of the same seeds.
> - Selection sensitivity: selected vs alternative G, evaluated from saved parameters (no refit).
> - External validation: ARI, NMI and cross-tables; matched agreement reported separately.
> - Profiling, plus a descriptive strata check.
> - Bootstrap/subsampling and split-sample validation are NOT RUN (optional, need approval).
> - New heuristic thresholds are listed in `decision-tree-alignment.md` B13.
> - The report text depends on the analysis state, not on a dataset. Without external labels, 6C reads "External Validation: Not Performed" and 6D has no label columns. Independence comes only from the Stage 3 status field and its recorded note; no repeated-measurement statement is generated. With no alternative G, Stage 6 completes and states "No alternative G was compared". Substantive interpretation stays "not established by this analysis".

**Status:** decision specification, not evaluated results. Hair et al., *Multivariate Data Analysis*, 8th ed., Chapter 4 pp. 228–229 introduces split-sample validation, criterion validity, and profiling with external variables. The checks below translate these ideas into GMM-specific diagnostics. Hair's broad cluster-assignment change heuristics are not universal GMM acceptance thresholds and must not be treated as mandatory pass/fail rules.

## V01 — Numerical and restart stability (required)

Read Stage 4 `fit_status.csv` for all attempted starts. Show converged/failed counts and distributions of valid final log-likelihoods. Compare near-optimal solutions of the same G (and model) after handling **label switching**: component matching on means/parameters or comparing partitions via a permutation-invariant metric such as adjusted Rand index (ARI). A high-likelihood near-degenerate run must not be promoted as valid. If only one valid run exists, mark evidence for stability as limited; warn rather than claiming validation.

## V02 — Model-selection sensitivity (required)

Plot AIC/BIC for *comparable*, converged valid candidates with sign convention from Stage 4. Show selected G, second-best alternatives, delta BIC, candidates and failures. If selected G lies at the maximum searched G, flag a boundary warning and offer an explicitly approved expanded search. If AIC disagrees with BIC, explain criteria's different complexity penalties; this is not inherently a model failure. If two candidates have similar BIC and meaningfully different substantive profiles, present both and discuss model-selection uncertainty; do not automatically switch away from a BIC choice without disclosure.

## V03 — Posterior classification quality (required)

Report summary of maximum posterior probability, uncertainty `1-max tau`, entropy and MAP group proportions. These are classification separation diagnostics, not proof that the Gaussian mixture density is correct. `G=1`: classification quality is not informative (posterior=1 by construction); report explicitly.

## V04 — Split-sample / holdout density validation (optional, recommended when n permits)

Create a reproducible split or folds only upon approved validation plan; fit on training observations *including any learned transformations fit on training only*, then evaluate independent hold-out **predictive log-density** `sum_j log f(x_j; theta_train)`, and preferably mean per observation. For comparisons, use the same hold-out rows and transform choices; if scale changes, compare only appropriate consistent densities. State that held-out log-density measures density prediction, not clustering accuracy. Repeated splits/folds require independent fit of each split and a defined aggregation; do not imply monotone EM on held-out data.

## V05 — Stability under resampling (optional)

Bootstrap or repeated split fits can compare cluster structure, but component count and labels may change. Report matching choices and distinguish conditional stability at fixed G from stability of model selection over G. Use ARI only for partitions over the same observations, or use matched posterior/co-clustering summaries; do not calculate ARI across non-overlapping observation sets.

## V06 — External criterion validation (conditional)

If external labels or independent variables were provided but excluded from fit, compare component memberships with these outcomes after estimating GMM. Label these comparisons descriptive/post-hoc unless the user pre-registered a valid inferential procedure. External labels are not allowed as fitted features for the unsupervised task. A high ARI with known labels can be reported where appropriate, but not presented as a GMM assumption test.

## V07 — External profiling (conditional)

Describe each component using preidentified *unused* descriptive variables and report sample size and missingness for these variables; do not silently include them in GMM. Profiles and naming require practical or theoretical support. Standard p-values from testing a group created using the same analyzed variables are subject to selection bias; avoid unadjusted inferential claims, particularly when comparing the same fitting features.

## V08 — Reporting and decision statuses

`CHECKS_COMPLETE_WITH_LIMITATIONS`: required diagnostics complete, valid model selected; optional validation may be absent and must be marked `NOT_RUN` and disclosed. `WARNING`: instability, boundary optimum, uncertainty, or weak external replication; preserve model and caveats. `INCONCLUSIVE`: cannot establish sufficient evidence; report diagnostics without overclaiming. `STOP`: discovered invalid selected model or mismatch in data provenance; return to Stage 4. No 'fully valid' proof by a single diagnostic; never silently delete observations or refit with unapproved changes.

**Artifacts**: `validation_summary.json`, `restart_stability.csv`, `model_sensitivity.csv`, optional `holdout_validation.csv`, optional `external_profile.csv`, `validation.md` (planned names).

**Objective routing:** if `objective=density`, report predictive density and numeric diagnostics without requiring group naming or external cluster profiling.
