# Pending review: heuristic thresholds and project choices

**Generated from the code** (`report_final.R::gmm_heuristics_registry()`). The final report embeds the same list (Appendix A) and writes `pending_heuristics.csv`.

Every item below is a **project screening choice**. None is a textbook rule, and none has been calibrated by simulation (review item R07).
- Each keeps the status PENDING REVIEW until the user confirms it.
- Changing a value is a specification change: it needs approval and a rerun of the affected stages.
- Exact rules are not listed here; they are fixed by mathematics or by the confirmed spec. Examples: n/G < p+1 → STOP, k_G ≥ n → STOP, the BIC/AIC formulas, U = 1 − max τ.

| # | Stage | Name | Value | Type | Use | Code location | Status |
|---|---|---|---|---|---|---|---|
| 1 | 2 (EDA) | abs_r flag | 0.9 | heuristic | \|Pearson r\| above this is flagged | `eda_stage2.R EDA_FLAG_ABS_R` | PENDING REVIEW |
| 2 | 2 (EDA) | condition index flag | 30 | heuristic | sqrt(lambda_max/lambda_min) of correlation flagged | `eda_stage2.R EDA_FLAG_CONDITION` | PENDING REVIEW |
| 3 | 2 (EDA) | VIF flag | 10 | heuristic | VIF above this is flagged | `eda_stage2.R EDA_FLAG_VIF` | PENDING REVIEW |
| 4 | 2 (EDA) | IQR outlier rule | 1.5 x IQR | heuristic (Tukey) | boxplot whiskers / outlier counts | `eda_stage2.R` | PENDING REVIEW |
| 5 | 2 (EDA) | |z| outlier count | 3 | heuristic | count of \|z\| > 3 | `eda_stage2.R` | PENDING REVIEW |
| 6 | 2 (EDA) | scatter-matrix size limit | 12 | display choice | scatterplot matrix skipped above this many variables | `eda_stage2.R` | PENDING REVIEW |
| 7 | 2 (missing) | KNN k suggestion | 5 | heuristic | suggested default k; user chooses | `SKILL.md / data_stage2.R` | PENDING REVIEW |
| 8 | 3 | min_unique_values | 10 | heuristic | fewer unique values -> confirm the variable is continuous (PAUSE) | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 9 | 3 | max_value_share | 0.2 | heuristic | one value holding a larger share of rows -> tie/degeneracy WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 10 | 3 | condition_index_corr | 30 | heuristic (Belsley condition index) | sqrt(lambda_max/lambda_min) of the correlation matrix -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 11 | 3 | vif | 10 | heuristic | variance inflation factor -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 12 | 3 | abs_r | 0.9 | heuristic | \|Pearson r\| -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 13 | 3 | sd_ratio_scale | 10 | heuristic | max SD / min SD across features -> z-score is recommended more strongly | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 14 | 3 | cov_condition_numeric | 1e+10 | heuristic (double-precision safety) | lambda_max/lambda_min of the covariance on the chosen scale -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 15 | 3 | mahalanobis_quantile | 0.999 | screening | chi-square(p) quantile for global Mahalanobis D^2 screening -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 16 | 3 | abs_skew | 2 | heuristic (West, Finch & Curran 1995) | marginal \|skewness\| -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 17 | 3 | excess_kurtosis | 7 | heuristic (West, Finch & Curran 1995) | marginal excess kurtosis -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 18 | 3 | obs_per_param_per_component | 5 | heuristic | n/G below 5 x per-component parameters -> WARNING | `feasibility_stage3.R STAGE3_THRESHOLDS` | PENDING REVIEW |
| 19 | 4A-4B | min_effective_n | p + 1 | heuristic | EM guard: smaller effective component size -> DEGENERATE | `em_stage4.R` | PENDING REVIEW |
| 20 | 4A-4B | max_cov_condition | 1e+10 | heuristic | EM guard: covariance condition number -> DEGENERATE | `em_stage4.R EM_DEFAULTS` | PENDING REVIEW |
| 21 | 4A-4B | log-lik decrease bands | noise <= 1e-10; flagged > 1e-10; error > 1e-06 | heuristic | monotonicity checks | `em_stage4.R EM_DEFAULTS` | PENDING REVIEW |
| 22 | 4A-4B | initialisation | kmeans | project choice | k-means hard partition per start | `em_stage4.R` | PENDING REVIEW |
| 23 | 4C-4D | same_optimum_loglik_rel | 1e-06 | heuristic (= convergence tol) | starts within this relative log-lik gap may share an optimum | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 24 | 4C-4D | same_optimum_param | 0.01 | heuristic | and max \|difference\| of aligned pi, mu, Sigma (fitted scale) below this | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 25 | 4C-4D | small_component | 5 x (p + p(p+1)/2) effective rows | heuristic (as Stage 3 S3-11) | WARNING for the selected fit of each G | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 26 | 4C-4D | cov_condition_warning | 1e+06 | heuristic | WARNING: ill-conditioned component covariance | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 27 | 4C-4D | single_start_optimum | best optimum reached by < 2 starts | heuristic | WARNING: optimum may not be stable | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 28 | 4C-4D | failed_start_fraction | 0.5 | heuristic | WARNING when more than half of the starts are not CONVERGED_VALID | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 29 | 4C-4D | delta_bic_alternative | 6 | heuristic (Kass & Raftery 1995 evidence scale) | eligible models with delta BIC <= 6 are kept as alternatives for Stage 6 | `select_stage4.R S4_THRESHOLDS` | PENDING REVIEW |
| 30 | 5 | ambiguous | 0.1 | heuristic | observations with U_j > 0.10 are listed as ambiguous (not removed, not reclassified) | `interpret_stage5.R S5_THRESHOLDS` | PENDING REVIEW |
| 31 | 5 | descriptor | 0.5 | heuristic | a component mean is described as higher/lower than the overall mean when \|difference\| >= 0.5 overall SD | `interpret_stage5.R S5_THRESHOLDS` | PENDING REVIEW |
| 32 | 6 | trivial_partitions | ARI = NMI = 1 if both partitions have one cluster; NMI = 0 if exactly one is trivial | convention |  | `validate_stage6.R S6_THRESHOLDS` | PENDING REVIEW |
| 33 | 6 | split_share | 0.1 | heuristic | an alternative-model component counts as a child of a selected-model component if it takes >= 10% of that component | `validate_stage6.R S6_THRESHOLDS` | PENDING REVIEW |
| 34 | 6 | split_purity | 0.8 | heuristic | ... and >= 80% of the child component comes from that parent | `validate_stage6.R S6_THRESHOLDS` | PENDING REVIEW |
| 35 | 6 | matched_agreement | optimal one-to-one matching of components to labels (exhaustive search, max(G, K) <= 8) | descriptive | reported separately from ARI/NMI; unmatched components count as disagreement | `validate_stage6.R S6_THRESHOLDS` | PENDING REVIEW |
| 36 | 6 | NMI normalisation | arithmetic: 2I/(H(U)+H(V)) | choice | other normalisations exist (geometric, max) | `validate_stage6.R s6_nmi` | PENDING REVIEW |
| 37 | 4 (confirmation) | strict_tol | 1e-08 | heuristic | stricter relative log-likelihood tolerance used to continue each valid start | `confirm_stage4.R CONFIRM_THRESHOLDS` | PENDING REVIEW |
| 38 | 4 (confirmation) | strict_max_iter | 5000 | heuristic | total EM iterations allowed per start, counted from its initialisation | `confirm_stage4.R CONFIRM_THRESHOLDS` | PENDING REVIEW |
| 39 | 4 (confirmation) | premature_gain_abs | 0.1 | heuristic | same-start gain >= this -> POSSIBLE_PREMATURE_STOP; also the margin for BETTER_OPTIMUM_HIDDEN and AT_STRICT_BEST | `confirm_stage4.R CONFIRM_THRESHOLDS` | PENDING REVIEW |
| 40 | 4 (confirmation) | replay_match_abs | 1e-08 | heuristic | largest \|replay - recorded\| log-likelihood accepted as the same run | `confirm_stage4.R CONFIRM_THRESHOLDS` | PENDING REVIEW |
| 41 | 4A-4B | random-soft responsibilities | Dirichlet(1,...,1) | heuristic | distribution of the initial responsibilities for init = random-soft; not adjustable by the user | `em_stage4.R em_init_soft_tau` | PENDING REVIEW |

Related specification differences awaiting review are listed in `decision-tree-alignment.md`: A9, B1, B2, B4, B5, B8, B10–B13.
