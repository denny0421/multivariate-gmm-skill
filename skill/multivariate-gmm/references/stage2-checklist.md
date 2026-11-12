# Stage 2 Checklist — data profiling, EDA and missing-data handling (v0.5)

Applies to every dataset whose selected modelling features are continuous numeric. All items are produced by one command, `scripts/data_stage2.R` (EDA comes from `scripts/eda_stage2.R`). Do not write ad-hoc analysis scripts for these items. Labels follow `checklist.md`: `PASS`, `WARNING`, `PAUSE`, `STOP`. Items D01–D05 feed checks C03–C07 there.

## D. Data integrity and missingness

| ID | Item | Evidence file | Rule |
|---|---|---|---|
| D01 | Roles recorded: features, external label (`--label`), excluded columns | `run_config.json`, `summary.json` | A label is never an analysis column, and it is never used in statistics, plots or processing |
| D02 | NA, NaN and Inf counted separately by variable | `variable_missing.csv`, `summary.json` | Inf → STOP processing until corrected (EDA is skipped too) |
| D03 | Missingness patterns and all-missing rows | `pattern_summary.csv`, `missingness_map.png`, `missing_rate.png`, `summary.json$all_missing_source_rows` | Do not infer MCAR/MAR/MNAR from counts; ask about the study design |
| D04 | Missing-data choice made by the user | `missing-data-menu.md` | PAUSE until the user chooses; then run with `--approved true` |
| D05 | Processing recorded | `preprocessing_log.json` | Removed source row IDs, imputed cells, k, input MD5 |

## E. Exploratory data analysis (all numeric datasets, with or without missing values)

| ID | Item | Evidence file (`eda/`, plus `eda_processed/` after processing) | Typical status |
|---|---|---|---|
| E01 | Descriptive statistics: n observed/missing, mean, SD, CV, min, quartiles, max, IQR, skewness, excess kurtosis, unique values | `descriptive_stats.csv` | PASS when reviewed |
| E02 | Distributions: histogram + kernel density + rug per variable | `distributions.png` | WARNING if strongly skewed or multimodal — informative for GMM, not a defect |
| E03 | Boxplots with 1.5×IQR whiskers; counts of IQR and \|z\|>3 outliers | `boxplots.png`, `descriptive_stats.csv` | WARNING (C07) for extremes; never delete automatically |
| E04 | Scatterplot matrix with lowess and pairwise r/ρ/n (skipped above 12 variables) | `scatter_matrix.png` | Exploratory only; visible groupings are not evidence of clusters |
| E05 | Correlation analysis: Pearson, Spearman, pairwise n, per-pair 95% CI and p-value | `correlation_*.csv`, `correlation_heatmap.png` | WARNING for \|r\| > 0.90 |
| E06 | Basic collinearity on complete rows: zero variance, eigenvalues, condition number, rank, VIF | `collinearity.json` | Zero variance or rank deficiency → STOP for full covariance (C05); condition number > 30 or VIF > 10 → WARNING |
| E07 | Scale review: compare SDs and units across variables | `descriptive_stats.csv` | PAUSE for a standardization decision before Stage 3 (C06) |
| E08 | Processed data re-checked after removal or imputation | `eda_processed/` | Compare with `eda/`; imputation can shrink variance and distort correlations |

Statistical bases: univariate statistics use each variable's observed values (available-case); correlations use pairwise-complete pairs; collinearity uses rows complete on all features. The thresholds 0.90, 30 and 10 are heuristic screening flags (project choices), not textbook rules. High correlation alone is not a reason to drop a variable.

## Handoff to Stage 3

Present D01–D05 and E01–E08 to the user, including the flags, and get a **second explicit confirmation** before any Stage 3 work. This version stops at that point (`next_action = USER_APPROVAL_THEN_STAGE3`).
