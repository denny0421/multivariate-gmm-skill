# GMM Statistical Checklist — v1.4

> Apply **before EM**. Labels are `PASS`, `WARNING`, `PAUSE`, `STOP`. A WARNING can permit fitting *after documented informed approval*. A PAUSE blocks fitting until a user decision; a STOP blocks the requested configuration until redesigned. A fit never automatically proceeds from a STOP.

| ID | Check | PASS | WARNING / PAUSE | STOP | Record |
|---|---|---|---|---|---|
| C01 | Objective is in scope | Unsupervised clustering or continuous density | Purpose ambiguous → PAUSE | Supervised-only / another model required | `objective` |
| C02 | Observation unit and independence | Known, defensible independent rows | Unknown → PAUSE to clarify | Confirmed dependence under independent-row specification | `unit`, `dependence` |
| C03 | Selected feature semantics | Continuous numeric | Integer-coded or ordinal ambiguous → PAUSE | Pure categorical input for Gaussian fit | `features`, `feature_types` |
| C04 | Data integrity | Selected entries finite | NA/NaN present → PAUSE and enter the missing-data menu (complete-case / mean / median / KNN / diagnostics only; the user chooses and approves); Inf/-Inf present → STOP model estimation until corrected; report counts by row/column | No valid approved handling leaves eligible rows | `missing_summary` |
| C05 | Constant / redundant columns | No exact dependencies | Very high correlations → WARNING | Exact dependencies for full-covariance fit | `rank`, `problem_columns` |
| C06 | Scale and transforms | Choice recorded | Scale changes may matter → PAUSE for approval; z-score is the recommended default, never forced (v1.4) | Any unapproved transform | `standardize`, `transform_params` |
| C07 | Outlier assessment | Reviewed | Extremes may drive spurious component → WARNING | Outliers alone do not mandate STOP | `outlier_summary` |
| C08 | Sample size / p / G | Feasible candidate settings | Limited n relative to complexity → WARNING | No estimable user-approved configuration | `n`, `p`, `G_candidates`, `k_per_model` |
| C09 | Gaussian working model | Reasonable as approximation | Skew/heavy tails and fit uncertainty → WARNING | User requires incompatible distribution without accepting caveat | `model_assumptions` |
| C10 | Covariance structure | Explicit, feasible | Full structure fragile → WARNING | No valid positive-definite fit attainable | `covariance` |
| C11 | User approval gate | Clear approval of variables/configuration | Some choice unresolved → PAUSE | User refuses required revision | `approval` |
| C12 | Convergence (Stage 4) | Finite valid fit, no critical numerical warning | Slow, local optimum, small components → WARNING | Failed/invalid fit cannot be selected | `fit_status`, `ll_history` |
| C13 | Model selection (Stage 4) | Comparable valid candidates, consistent BIC convention | Some candidates failed → WARNING | No valid candidates | `selection_table` |
| C14 | Interpretation (Stage 5) | Probabilities and caveats included | Overlapping components → WARNING | Never assert latent components are verified classes | `uncertainty` |
| C15 | Validation (Stage 6) | Stability, sensitivity and limits reported | Stability unclear → WARNING | Report must not hide failed validation | `validation` |

Stage 2 evidence for C03–C07 (data integrity, missingness, EDA, collinearity, scale, outliers) is itemised as D01–D05 / E01–E08 in [`stage2-checklist.md`](stage2-checklist.md) and produced by `scripts/data_stage2.R`. Stage 3 gate decisions for C01–C11 are implemented as S3-01 to S3-15 in [`stage3-checklist.md`](stage3-checklist.md) (`scripts/feasibility_stage3.R`). See [`stage4-checklist.md`](stage4-checklist.md) for M01–M14; [`stage5-checklist.md`](stage5-checklist.md) for I01–I12; and [`stage6-checklist.md`](stage6-checklist.md) for V01–V12.

## Approval-gate script (for Claude Code)

Before fitting, present: (1) confirmed objective and observation unit; (2) selected variables and any excluded observations; (3) missingness handling; (4) scale/transform decision; (5) proposed `G_candidates` and covariance structure; (6) numerical safeguards and warnings; (7) outputs. Ask once: **「上述分析設定是否確認？確認後才會執行模型估計。」**

If the user has already explicitly approved this exact immutable specification, cite that approval in the audit instead of asking them to repeat it. Any material change to data, variables, transformation or model settings requires fresh approval.

## Required machine-readable audit fields (future R implementation)

```json
{
  "status": "PAUSE",
  "stage": 3,
  "checks": [
    {"id": "C04", "status": "PASS", "evidence": "No non-finite values in selected features"},
    {"id": "C06", "status": "PAUSE", "evidence": "Scale decision not approved"}
  ],
  "outstanding_decisions": ["Confirm standardization"],
  "approved_for_fit": false
}
```

Example is a **schema illustration**, not the result of running on any actual dataset.

## Warnings that must not be silently overridden

- A GMM *component* is a probability density component, not necessarily a natural cluster.
- Do not use a global multivariate-normality test as a mandatory prerequisite for GMM.
- Do not infer statistical independence or measurement semantics from a CSV alone.
- Never delete outliers or impute/drop missing rows without a documented decision.
- Correlations can matter substantively and numerically; high correlation is not automatically a reason to discard a variable.
- Default candidate range `1:5`, start count `20`, tolerance `1e-6`, etc. are **project choices to validate**, not textbook rules.
