# Stage 3 Checklist — assumptions and feasibility for a full-covariance GMM (v0.1)

Produced by `scripts/feasibility_stage3.R` on a complete numeric dataset (normally the Stage 2 `processed_data.csv`). It writes `stage3_checks.json` / `.csv`, `candidate_feasibility.csv`, `variable_diagnostics.csv`, `outlier_screening.csv`, `stage3_spec.json` and `stage3_report.md`. **No EM, likelihood, BIC or model estimation is performed.** No global multivariate-normality test is required.

Overall status = the worst check status (STOP > PAUSE > WARNING > PASS). PAUSE and STOP cannot be bypassed by approval.

| ID | Maps to | Check | PASS | WARNING | PAUSE | STOP | Statistical reason |
|---|---|---|---|---|---|---|---|
| S3-01 | C04 / Q4 | Input integrity | numeric, finite, complete | — | NA/NaN present (return to Stage 2) | non-numeric, Inf, n < 2 | The likelihood needs complete finite vectors |
| S3-02 | C03 / Q3 | Continuous semantics | ≥ 10 distinct values | — | < 10 distinct values: confirm the semantics | — | Gaussian components assume continuous measurement |
| S3-03 | C05 / Q5 | Zero variance | none | — | — | any constant feature | Singular covariance → density undefined |
| S3-04 | C05 / Q5 | Rank | rank = p, n > p | — | — | rank < p or n ≤ p | Exact dependency → every covariance singular |
| S3-05 | C05 | Near-collinearity (correlation scale) | below flags | condition index > 30, VIF > 10 or \|r\| > 0.90 | — | — | Ill-conditioned within-component covariances; not a reason to drop variables |
| S3-06 | C06 / Q6 | Scale decision | decision recorded | `none` with SD ratio > 100 | no decision (z-score recommended) | — | The unconstrained full-covariance ML partition is scale-equivariant; z-scores help conditioning and initialisation |
| S3-07 | C07 | Outliers | none flagged | global D² > χ²(p, 0.999) | — | — | Extreme points can capture a collapsing component; under a mixture, D² is only a screen |
| S3-08 | C10 | Ties / duplicates | below flags | ≥ p+1 identical rows, or one value in > 20% of rows | — | — | A component on tied points → singular covariance, unbounded likelihood |
| S3-09 | C10 | Pooled covariance | PD, condition number ≤ 1e10 on the chosen scale | condition number > 1e10, or Cholesky fails in original units only | — | not PD on the correlation scale | Component covariances are estimated from fewer rows than the pooled one |
| S3-10 | C09 / Q8 | Gaussian working model | below flags | \|skew\| > 2 or excess kurtosis > 7 | — | — | Only components are Gaussian; skew or tails may add spurious components |
| S3-11 | C08 / Q9 | Candidate G, k_G = (G−1) + Gp + Gp(p+1)/2 | all feasible | some n/G < 5 × (p + p(p+1)/2), or G = 1 absent | some candidates STOP (user revises the set) | all candidates STOP (G ∉ 1..n, k_G ≥ n, n/G < p+1) | n/G < p+1 forces a component with < p+1 rows (exact singularity) |
| S3-12 | C10 | Covariance structure | full, component-specific (VVV) | — | — | — | Other families need a separate spec and parameter count |
| S3-13 | C01 / Q1 | Objective | clustering or density recorded | — | not recorded | — | Routes the Stage 5/6 reporting |
| S3-14 | C02 / Q7 | Independent rows | confirmed from the design | working assumption (`assumed`, note required) | not confirmed | user reports dependence | The likelihood multiplies row densities; independence cannot be proven from the data |
| S3-15 | C11 / Q10 | Approval | approved, nothing blocking | — | not approved, or blocked | any STOP | The fit uses only the exact approved spec |

**Thresholds** marked heuristic (10 distinct values, 0.90, 30, 10, 100, 0.999, 20%, 1e10, skew 2 / kurtosis 7, 5×) are project screening choices recorded in `stage3_checks.json$thresholds`. They are not yet calibrated by simulation (review item R07). The conditions n/G < p+1 and k_G ≥ n are exact.

**Data change policy.** The input is never modified. `transformed_data.csv` (z-scores) and `transform_params.csv` (centre/SD per feature, for back-transformation) are written only when `--scale zscore` and `--approved true` are given and no PAUSE/STOP remains.

Differences from the Decision Tree v1.3 text are listed in `decision-tree-alignment.md` (section B).
