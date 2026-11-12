# Classroom Demonstration Protocol: Complete vs Missing Data

**Status:** design/teaching protocol; no missing-data GMM algorithm is implemented.

## Purpose

Demonstrate both (1) successful model-based clustering using a complete continuous dataset and (2) correct handling of missing data via a safety/analysis decision gate. Optionally demonstrate what changes after approved complete-case deletion. This is **not** an evaluation of missing-data EM, which is outside the initial scope.

## Paired datasets

- Generate an underlying complete multivariate Gaussian mixture sample using a fixed seed. Preserve `row_id`, selected continuous variables, `true_component` (held back from fitting, evaluation only).
- `complete.csv`: original complete observations.
- `missing.csv`: same rows and true data before masking, with a documented missingness mechanism in selected features and an NA indicator. Preserve ground-truth complete data separately solely for simulation evaluation.
- Start with an MCAR design with a declared probability; add MAR as a **separately labeled optional scenario** only if the team has time. Do not label dropout or selection rules as MAR/MCAR without checking their actual dependence assumptions. Record intended and realized missing rates.
- For an observable comparison, use enough observations to avoid near-singular component covariance; perform a feasibility check after any removal.

## Branches

### Case A: Complete data

1. Read data and confirm all analysis features are continuous, finite and complete.
2. Check rank, scale, potential outliers, observation-unit independence.
3. Obtain user confirmation of G range, covariance, transformations and seeds.
4. Once tested R scripts exist: fit multi-start EM, retain only valid converged fits, compute BIC/AIC, posterior probabilities and diagnostics.
5. Interpret, validate, export reports and exact modeling metadata.

### Case B: Missing data

1. Read data without modifying the source; report NA/NaN counts and percentages by feature, and complete-case sample size. Flag Inf separately.
2. PAUSE fitting of the original missing dataset. Explain that the core full-data GMM EM does not directly handle incomplete rows.
3. Offer user: (a) diagnostic-only report without a fit; (b) explicit approval for complete-case preprocessing and a **complete-case GMM** with its limitations; (c) externally prepared/approved alternative dataset. Future extensions may add a distinct missing-aware GMM estimator, but do not simulate its availability.
4. For (b), record excluded `row_id`, retained n, missingness and loss fraction, preprocessing decision and risk of selection bias. Re-run Stage 2–3 feasibility gates on retained rows, and obtain final approved specification. No silent deletion.
5. Fit with the same documented model specification *where feasible*, and compare parameter estimates and clustering cautiously against Case A. Align component labels before comparing. Note complete-case estimates may be biased under MAR or MNAR, and efficiency is reduced even under MCAR.
6. Compare **within-dataset** candidate BIC scores; do not directly compare absolute BIC values across complete vs reduced datasets as evidence of improved fit. Cross-sample differences in fitted parameters, cluster allocations for retained rows, classification uncertainty and sample composition are more informative.

## Minimum visual/report outputs

- Missingness heatmap or matrix and per-feature missing percentage.
- Count of complete vs retained observations, and proportion excluded.
- Side-by-side cluster visualization (same selected variables / fixed projection, clearly showing differing n).
- Parameter/profile comparison after label alignment (when valid fits exist).
- Explicit box/paragraph explaining what could **not** be inferred about the missingness mechanism from observed data alone.

## Test assertions

- No fitting is attempted on missing analysis entries without an approved preprocessing/estimator branch.
- Original files are never overwritten.
- Row IDs are stable and excluded rows are enumerated.
- Numeric summaries reflect the actual files and are not AI-generated estimates.
- The report states 'complete-case GMM' where used, never 'missing-data EM'.
