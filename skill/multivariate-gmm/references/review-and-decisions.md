# Cross-stage Decision Tree Review — v1.3 (status notes updated for v1.4)

> v1.4 status (2026-11-07):
> - R02 is implemented: NA/NaN → missing-data menu; Inf → STOP estimation.
> - R07 now has code, but its thresholds are still unvalidated heuristics, recorded in the Stage 3 output.
> - The other findings are unchanged.
> - Open specification differences are listed in `decision-tree-alignment.md`.

**Scope:** design review only; no R fitting or automated tests have run. Structural source: Hair et al., *Multivariate Data Analysis*, 8th ed., Chapter 4 six stages. GMM numerical and operational rules are project specifications, not quotations from Hair.

## Findings and resolutions

| ID | Priority | Observation in v1.2 | Resolution for v1.3 | Status |
|---|---|---|---|---|
| R01 | High | Approval text alternates between always asking and skipping a second question. | Exact-config explicit approval can be reused; any materially changed specification must be approved. Record `approval_id`, `spec_hash`. | Rule clarified; code pending |
| R02 | High | `missing/Inf` grouped together as one recoverable condition. | NA/NaN -> PAUSE for approved handling; infinite values -> STOP current dataset until corrected and provenance recorded. | Rule clarified; code pending |
| R03 | High | Stage 1 permits density estimation but Stage 5/6 assume interpretable clusters. | `objective` routes to distinct report branches: clustering requires partition description; density-only does not require cluster labels, profiling or external label validation. | Rule clarified; code pending |
| R04 | High | Candidate failure and full-run failure statuses are not uniformly distinguished. | Single start `FAILED_START`, candidate `FAILED_CANDIDATE`, workflow `STOP_NO_VALID_MODELS`. Candidate failures do not forbid choosing other valid candidates. | Contract specified |
| R05 | High | `VALIDATED WITH LIMITATIONS` could imply optional validation was done. | Require only numerical/restart, selection sensitivity, posterior summary, provenance; explicitly label holdout, resampling and external validation `NOT_RUN` where absent. Use `CHECKS_COMPLETE_WITH_LIMITATIONS`, not proof of validity. | Rule clarified |
| R06 | Medium | BIC formula and sign choice are correct but selection comparison conditions need a formal gate. | Require identical approved data matrix, likelihood convention, transform and parameter count; invalid or not-converged models excluded, not assigned arbitrary numeric penalties. | Contract specified |
| R07 | Medium | GMM rank/positive-definiteness checks lack concrete numeric threshold. | Check structure before fit, provide scale-aware diagnostics after; record `thresholds_unvalidated=true` until simulation calibration. No universal n>k claim. | Unresolved numeric validation |
| R08 | Medium | Stage 5 back-transformation clear for affine transforms but outputs are not versioned. | Record transforms (centering/scaling) and export native-scale plus fitted-scale model parameters; exact row ID and model ID joins. | Contract specified |
| R09 | Medium | Different documents use PASS/WARNING/PAUSE/STOP/FAILED/INCONCLUSIVE differently. | Centralize decision and execution statuses in `stage-contract.md`. | Contract specified |
| R10 | Medium | `fit_status`, `selected_model`, `model_selection` listed without a machine-readable contract. | Specify required handoff fields and null/NA behavior. | Contract specified |
| R11 | Low | Stage 5 and 6 may run in arbitrary order in documents. | Stage 5 descriptive interpretation first, Stage 6 evidence/validation next, then final report updates qualified claims. No optional validation may be presented as already performed. | Rule clarified |
| R12 | Medium | Numerical convergence and regression validation are design assumptions only. | R implementation must include multi-seed synthetic test, monotonicity tolerance, singular data test, label-switching invariant comparison, mclust benchmark. | Pending implementation |

## Fixed design constraints

- First version: independent rows of complete continuous features, component-specific full-covariance Gaussian mixtures.
- No silent row deletion, imputation, transformation, regularization or covariance change.
- `G=1` must be a candidate when searching includes it and is an allowed outcome.
- Model selection BIC convention in documents: `-2 logLik + k log n` (smaller is better). Convert `mclust` sign before comparison.
- Diagnostic/validation warnings do not transform statistical components into verified natural groups.

## Remaining items before R implementation

1. Select initialization family, deterministic start-seed schedule and tie policy.
2. Calibrate convergence, monotonicity, covariance eigenvalue, effective membership and minimum-weight criteria using simulations; document tolerances and data scale.
3. Define fixed schemas and implement serializations (`spec`, fit start table, selection table, posterior/row alignment, figures).
4. Build repeatable R tests and audit every STOP/PAUSE branch.
