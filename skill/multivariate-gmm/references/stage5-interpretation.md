# Stage 5 — Interpretation of Clusters (v1.2)

> **Implementation status (2026-11-07):** implemented in `scripts/interpret_stage5.R` (tests: `tests/test_interpret.R`).
> - Implemented: I01 posterior validation (including re-computation from the stored parameters, which detects label switching); back-transformation μ_o = m + Sμ_z, Σ_o = SΣ_zS with a posterior-invariance check; uncertainty and normalised entropy; π vs MAP; generic profiles and figures.
> - Not implemented: Stage 6 items (external labels, stability).
> - New heuristic thresholds are listed in `decision-tree-alignment.md` B12. The text below remains the governing specification.

**Status:** design specification, not a fitted model. Hair et al., *Multivariate Data Analysis*, 8th ed., Chapter 4 pp. 227–228 motivates interpreting the cluster profiles on original variable scales and examining meaningful descriptive differences. Hair also describes assigning descriptive labels to clusters from their profiles; this Skill deliberately does **not** name components. That is the Skill's own conservative interpretation rule (a Gaussian component is not necessarily a real group), not a recommendation from Hair. The Gaussian-mixture probability measures and safeguards below are additional model-specific specifications.

## Inputs and preflight

Required: approved specification and transformation metadata; selected_model.rds or equivalent verified model fit; model_selection.csv; fitted component weights, means and full positive-definite covariances; posterior n x G probability matrix; IDs for all retained rows; convergence and warning logs. Do not invent missing numerical outputs. No valid selected model => `STOP` to Stage 4 diagnostic report. Missing artifact => `PAUSE` and request computation/repair.

## I01 — Posterior validation

For every subject j, posterior `tau_ji` must be finite, lie in [0,1] within numerical tolerance, and sum to 1 within tolerance. MAP label is `argmax_i tau_ji`, with deterministic tie policy recorded. Always retain `row_id`, `MAP_component`, `max_posterior`, `uncertainty`, and all posterior columns; row order must match the approved data.

## I02 — Component size and summaries

Report **both** `pi_i` (estimated mixing weight) and `n_i^MAP/n` (fraction assigned to component i); do not equate them. Include mean vector `mu_i`, covariance matrix `Sigma_i`, within-component standard deviations and correlation matrix where defined; check positive definiteness and non-finite values. For `G=1`, uncertainty=0 and probability=1; report that the selected model contains only one Gaussian component, not discovered segmentation.

## I03 — Original-scale reporting

If an invertible affine transformation `z=A(x-c)` was fitted (e.g., column-wise standardization), back-transform means `mu_x=A^{-1}mu_z+c` and covariances `Sigma_x=A^{-1}Sigma_z(A^{-1})^T`. Save both fitted-space and original-space values, with units; if transformation is not invertible, do not imply exact back-transformation is possible. Label any PCA projection as a visualization, not a substitute for the p-dimensional fit.

## I04 — Soft classification and uncertainty

Define `u_j=1-max_i tau_ji`, within [0,1-1/G]. Also record `H_j=-sum_i tau_ji log(tau_ji)` with 0 log 0=0; optionally normalized by log(G) only if G>=2. Report mean/median uncertainty and empirical distribution; avoid universal 'high uncertainty' cutoff. If users preapprove a cut-off, mark it as a descriptive operational threshold, not a probabilistic significance test. Distinguish uncertainty due to overlap from actual prediction error.

## I05 — Cluster descriptions and meaningful labeling

Describe each component with objective comparisons of original-scale means/variances, and domain/context if supplied. Label as `Component 1...G` by default. Propose descriptive names only when data and domain support them, and flag as provisional subject to user confirmation. Do not assert components are verified natural types or causal groups; do not use external labels to fit an unsupervised model unless analysis is redefined and reapproved.

## I06 — Visualization and output

Minimum: component mean profile (original units or clearly normalized for a *display-only* profile), estimated weights vs MAP proportions, posterior uncertainty distribution, model-selection plot from Stage 4. For p>=2 optionally show PCA scatter with MAP labels and uncertainty; if p=2, add density contours when numerically stable. Covariance heatmaps optional. Every plot uses clear axis units, fitted or projected space and data provenance.

## Interpretation decision outcomes

- `PASS`: complete verified output and appropriately qualified interpretation.
- `WARNING`: overlap, very small component, ambiguous semantics, or visually misleading projection; report limitations.
- `PAUSE`: missing required artifact or unresolved permission for subjective component names.
- `STOP`: no valid Stage 4 fit, invalid posterior values, or unrecoverable mismatched rows; do not synthesize results.

**Artifacts**: `component_summary.csv`, `classification.csv`, `posterior_probabilities.csv`, `uncertainty_summary.json`, `plots/`, `interpretation.md` (provisional filenames, to be implemented).

**Objective routing:** If `objective=density`, emphasize estimated density, model fit and numerical uncertainty; posterior and component summaries may be reported but labels/profiling are not mandatory.
