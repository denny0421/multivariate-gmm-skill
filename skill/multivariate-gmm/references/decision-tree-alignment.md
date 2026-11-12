# Decision tree vs. implementation — alignment record

**Status (2026-11-07):** The Decision Tree specification files were synchronised to **v1.4**, using only the rules the user confirmed:
1. Stage 2 runs the full EDA.
2. Missing data go through a user-selected menu.
3. Every deletion, imputation or standardization needs user approval.
4. Inf/−Inf block estimation; NA/NaN enter the missing-data workflow.
5. Stage 3 recommends z-score but never forces it.
6. The Stage 1–6 structure and the EM, BIC and AIC plans are kept.

Every other difference stays **pending review**. For those, the v1.3 wording and the existing implementation are both left unchanged, and no statistical decision condition was altered.

Legend:
- **Conflict**: the specification text and the implementation disagree.
- **Gap**: the specification is silent, and the implementation adds behaviour.
- **Doc**: wording or status that is out of date.
- **Resolved (v1.4)**: fixed by a user-confirmed rule.
- **Pending**: awaiting user review.

## Stage 2

| # | Type | Spec (v1.3) said | Implementation | Status |
|---|---|---|---|---|
| A1 | Conflict | Q4: "V1 does not itself impute, drop, or run missing-data EM". | User-approved complete-case, mean, median and KNN run inside Stage 2, with PAUSE menus and a log. | **Resolved (v1.4)**: Q4 and C04 now specify the menu and approval. |
| A2 | Conflict | Q4 grouped NA, NaN and Inf as PAUSE; C04/R02 said Inf → STOP. | Inf reported separately; processing refused; Stage 3 S3-01 = STOP. | **Resolved (v1.4)**: Inf/−Inf → STOP estimation; NA/NaN → missing-data workflow. |
| A3 | Doc | Scope: "complete multivariate continuous observations". | Incomplete data accepted at Stage 2, complete data required for estimation. | **Resolved (v1.4)**: scope sentence updated. |
| A4 | Gap | Interaction step 2: "scatterplots/pairs or a PCA visualization". | Full EDA module (descriptives, histograms, boxplots, pairs, correlations, collinearity); no PCA plot. | **Partly resolved**: the full EDA is now required (v1.4). *Pending:* whether a PCA plot is also required. |
| A5 | Gap | Q5/Q6 gate decisions belong to Stage 2. | Stage 2 EDA reports flags; the gate statuses are decided in Stage 3 (S3-03 to S3-08). | **Pending** |
| A6 | Gap | Q3: confirm integer or Likert semantics. | Stage 3 S3-02: fewer than 10 distinct values → PAUSE (heuristic). | **Pending** |
| A7 | Gap | Q7 independence is a Stage 2 question. | Asked at Stage 3 (S3-14). | **Pending** (placement) |
| A8 | Doc | Gate vocabulary PASS/WARNING/PAUSE/STOP. | Stage 2 emits workflow statuses and exit codes, not per-check gate labels. | **Pending** |
| A9 | Gap | No EDA or missing-data thresholds. | Heuristic flags: \|r\| > 0.90, condition index > 30, VIF > 10, 1.5×IQR, \|z\| > 3; KNN k = 5 suggested. | **Pending** |

## Stage 3

| # | Type | Spec (v1.3) said | Implementation | Status |
|---|---|---|---|---|
| B1 | Gap | Q8: WARNING for skew/tails; no global MVN requirement. | S3-10: \|skew\| > 2 or excess kurtosis > 7 → WARNING; never requires MVN. | **Pending** (thresholds) |
| B2 | Gap | Q9: parameter formula, 1–5 as default; no numeric rule. | S3-11 exact rules: G ∉ 1..n, k_G ≥ n, n/G < p+1 → STOP. Heuristic: n/G < 5 × per-component parameters → WARNING. Mixed set → PAUSE. G = 1 absent → WARNING. | **Pending** |
| B3 | Conflict (default) | Q6: neutral between original units and standardization. | z-score is the recommended default, a PAUSE until chosen, and transformed only after approval. | **Resolved (v1.4)**: Q6 and C06 say z-score is recommended by default and never forced. |
| B4 | Gap | Q6: report unusual observations; do not delete. | S3-07: global D² > χ²(p, 0.999) → WARNING (screen only). | **Pending** (threshold) |
| B5 | Gap | C10; R07 has no numeric thresholds. | S3-08 (≥ p+1 identical rows, one value in > 20% of rows) and S3-09 (PD on the correlation scale, condition number > 1e10). | **Pending** |
| B6 | Doc | `spec.json` / `approved_spec.json`. | Writes `stage3_spec.json` (with `spec_hash`, `approved_for_fit`, `approval_id`). | **Pending** (canonical name for the Stage 4 handoff) |
| B7 | Gap | C01 objective is a Stage 1 item. | Recorded at Stage 3 (S3-13). | **Pending** (placement) |
| B8 | Gap | The spec binds numerical settings and the random start schedule. | The Stage 3 spec records "not specified". Stage 4A–4B (`em_stage4.R`) records its settings in `em_summary.json`: tol 1e-6 relative, max_iter 1000, 20 starts, seed 421 (+ s − 1). These four were **specified by the user (2026-11-07)**. Project choices still awaiting review: k-means initialisation; `min_effective_n` = p + 1; `max_cov_condition` = 1e10; log-likelihood decrease bands (≤ 1e-10 noise, > 1e-10 flagged, > 1e-6 → `NUMERIC_ERROR`). | **Partly resolved**: the user-specified settings are applied. *Pending:* the project choices listed, and whether the settings should be bound into the Stage 3 spec hash. |
| B9 | Gap (new, 2026-11-07) | C02: unknown independence → PAUSE. Q7: UNKNOWN → WARNING + ask the user. | S3-14: undecided → PAUSE (C02). A user-declared **working assumption** (`--rows-independent assumed` plus a required note) → WARNING (Q7). Confirmed → PASS; dependence → STOP. Used for Palmer Penguins. | **Pending** (confirm that the WARNING category for working assumptions should be formalised) |

## Stage 4C–4D (added 2026-11-07)

| # | Type | Spec says | Implementation | Status |
|---|---|---|---|---|
| B10 | Gap | §4C: no universal thresholds; §4D: "near-ties … WARNING; request Stage 6 sensitivity", with no numeric definition. | `select_stage4.R` adds project heuristics: same-optimum rule (relative log-lik gap < 1e-6 and aligned parameter difference < 1e-2); SMALL_COMPONENT (effective n < 5 × (p + p(p+1)/2)); ILL_CONDITIONED_COVARIANCE (condition number > 1e6); SINGLE_START_OPTIMUM (< 2 starts); MANY_FAILED_STARTS (> 50%); Stage 6 alternatives = ΔBIC ≤ 6 (Kass & Raftery 1995 evidence scale). The user-specified rules are applied as given: BIC/AIC formulas, BIC as primary, exclusion of G without valid fits, boundary reminder without auto-extension. | **Pending** (approve the heuristic thresholds) |
| B11 | Gap | §4D: "BIC selects G=1 → report … do not force G≥2"; boundary only stated for the upper limit. | The boundary flag is raised only for the upper limit (as instructed). G = 1 can be selected and is reported as such. | **Pending** (should a lower-boundary note be added?) |

## Stage 5 (added 2026-11-07)

| # | Type | Spec says | Implementation | Status |
|---|---|---|---|---|
| B12 | Gap | Stage 5: report posterior uncertainty; no threshold for "ambiguous". The descriptive wording of components is not specified. | `interpret_stage5.R`: ambiguous = U > 0.10 (listed only; configurable). Generated descriptions call a mean "higher/lower than overall" when \|difference\| ≥ 0.5 overall SD. Both are labelled heuristic in `stage5_summary.json`. The user-specified rules are applied as given: back-transformation formulas, U = 1 − max τ, normalised entropy with G = 1 handled, π vs MAP distinction, no refit, no external labels, PCA marked as visualisation only. | **Pending** (approve the two heuristic thresholds) |

## Stage 6 (added 2026-11-07)

| # | Type | Spec says | Implementation | Status |
|---|---|---|---|---|
| B13 | Gap | Stage 6 gives no numeric rule for "split" or for describing G-vs-G structure. | `validate_stage6.R`: an alternative component is a child of a selected component if it takes ≥ 10% of it and ≥ 80% of the child comes from that parent (SPLIT / MIXED / KEPT labels). NMI uses arithmetic normalisation. Conventions for trivial partitions are recorded. Matched agreement uses exhaustive one-to-one matching (≤ 8 classes). The user-specified rules are applied as given: ARI/NMI, label-invariant comparison, labels read only in 6C and aligned by `source_row_id`, no refit, no re-selection, bootstrap optional, strata check descriptive. | **Pending** (approve the split thresholds and the NMI normalisation) |
| B14 | Gap | V01 requires restart stability. | Stage 4 does not save per-start classifications, so partition-level ARI between starts needs `--mode replay`. The replay uses the same per-start seeds and verifies that every start is reproduced. **Run for Palmer Penguins G = 3, 4 on 2026-11-08 with user approval**: all 40 starts reproduced (max relative log-lik difference 3.3e-15); the results are in `results/penguins/stage6/validation-G3-vs-G4-with-replay/`. | **Resolved for this analysis**. *Open:* whether Stage 4 should save per-start partitions in future, which would change an approved script, so it needs approval. |

## Documentation status

| # | File | Issue | Status |
|---|---|---|---|
| C1 | `stage-contract.md` | "Everything ... is a future implementation contract". | **Resolved (v1.4)**: Stage 2/3 marked implemented; Stage 4–6 still future. |
| C2 | `workflow-handoff.md` | "v1.2 has no executable scripts". | **Resolved (v1.4)** |
| C3 | `review-and-decisions.md` | R02 and R07 status. | **Resolved (v1.4)**: status note added. R07 thresholds remain unvalidated (tracked in A9, B1, B2, B4 and B5). |
| C4 | All spec files | Version label v1.3. | **Resolved**: `decision-tree.md`, `checklist.md`, `stage-contract.md` and `workflow-handoff.md` are labelled v1.4. `review-and-decisions.md` keeps the v1.3 review with v1.4 status notes. |

**Summary:** 27 items (the original 21 plus B9–B14).
- Resolved: 8 (A1, A2, A3, B3, C1–C4).
- Partly resolved: 3 (A4: PCA question open — a PCA *visualisation* now exists in Stage 5, but Stage 2 EDA has none; B8: EM project thresholds open; B14: replay done for Penguins, saving per-start partitions in Stage 4 is open).
- Pending: 16 (A5–A9, B1, B2, B4–B7, B9–B13).
