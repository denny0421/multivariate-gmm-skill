# Stage 2: Missing-data interactive menu

## Trigger
Run read-only data profiling once the analysis columns are chosen. For each selected variable report nonmissing count, NA/NaN count, missing rate; report Inf separately, complete rows, and observation-level missingness patterns. If `Inf` is present pause processing and ask for correction. Preserve source CSV.

## User choice (no implicit default)
When missing data are present, summarize diagnostics then let the user pick:

| Method | Executable | Decision constraint |
|---|---|---|
| Diagnostics only | yes | Save report only; no data changes, no GMM |
| Complete-case | yes | Warn on lost rows; possible selection bias; keep source row IDs |
| Mean imputation | yes | Warn variance/correlation and cluster structure may be distorted |
| Median imputation | yes | Warn distribution and covariance distortion |
| KNN imputation | yes | Ask for k; distance depends on selected predictors and scale; cannot impute with no observed predictor or donor (see KNN pauses below) |
| Multiple imputation | no | Future module: separate completed datasets and label alignment |
| Direct missing-data GMM EM | no | Future module: directly fit observed-data likelihood, not single imputation |

Never infer that small missingness guarantees MCAR; diagnostics cannot identify missingness mechanism from data alone. Ask about study design or missingness reasons when relevant.

## KNN pauses (exit code 2; nothing written)

**All-missing rows (`KNN_ALL_MISSING_ROWS`).** Before any imputation the script checks for observations whose selected variables are all NA/NaN and lists their source row IDs (also reported by diagnostics as `all_missing_source_rows`). It never drops them or silently fills them with mean/median. Present this menu and wait for the user's confirmation:

- **A.** Drop the all-missing rows and continue KNN on the remaining rows → rerun with `--all-missing-action drop --approved true`.
- **B.** Cancel KNN and return to the missing-data handling menu above.
- **C.** Output missing-data diagnostics only → `--method diagnostics`.

**No valid neighbours (`KNN_NO_VALID_NEIGHBORS`).** If, after any approved drop, a missing cell has no donor row that observes the target variable together with that row's observed predictors, no valid distance exists. The script lists every affected row/variable cell with the reason and imputes nothing. Offer: another method from the menu, revising the selected variables, or diagnostics only. There is no automatic fallback.

## KNN donor audit

Every KNN run writes these files to its Stage 2 folder. There is no option to turn them off, and they never change the imputation.

| File | One row per | Content |
|---|---|---|
| `knn_audit_cells.csv` | imputed cell | source row, variable, `k_requested`, `k_used`, `status` (`FULL_K`, `FEWER_THAN_K`), predictors used, other variables missing in that row, candidate donors, donors excluded for a missing predictor, `n_distinct_donor_profiles`, boundary tie, excluded tied rows, imputed value |
| `knn_audit_donors.csv` | donor of a cell | rank, donor source row, `distance`, `distance_squared`, donor value, `tied_with_previous` |
| `knn_audit_standardization.csv` | predictor of a cell | centre and scale from the candidate donors, `scale_rule` (`sd`, `set_to_1`), the target's value and z-score |
| `knn_audit_summary.json` | run | rule text, counts, checks, input hash, script version |

Reading it:
- The missing variable is never a predictor for its own cell. Each donor observes the target and every predictor of that row. Imputed values never act as donors.
- `tie_at_k_boundary` is the only tie that changes the donors: the smaller row position wins and the excluded rows are listed. It uses exact equality, as the ordering does.
- `n_distinct_donor_profiles` is descriptive. Do not present it as an effective sample size.
- A cell with no candidates still causes `KNN_NO_VALID_NEIGHBORS`, and nothing is written.

To audit a finished KNN run without touching it: `Rscript scripts/knn_audit.R replay --stage2-dir <dir> --output <new dir> [--input <file>]`. It first verifies the input hash, columns, k, missing positions, removed rows and row ID mapping, recomputes every cell, and compares all cells with `processed_data.csv` at that file's 15 significant digits. Any failure stops it, and no audit is written.

## Approval contract
First: after diagnostic report, user selects/approves method and settings. Second: after the processed-data summary, user approves modeling variables, any scaling, G candidates and model fit. The second gate cannot trigger GMM in v0.3 because fitting is pending.

## Outputs
`summary.json`: diagnostic counts (including all-missing rows), method, processing status. `preprocessing_log.json`: input path and MD5, method, approval, KNN k and cells with fewer than k donors, all-missing rows and the action taken, removed rows (count and source row IDs), imputed-cell counts per variable. `processed_data.csv`: source row IDs and chosen analysis columns, written only after approval; never overwrite input. `pattern_summary.csv`: O=observed, M=missing per chosen variable. `variable_missing.csv`: numerical missingness diagnostics. Two PNG plots and a text data summary (with the processed-data summary when applicable).

Each run also writes `run_config.json` (effective settings) and, unless `--eda false` or Inf is present, EDA under `eda/` for the input and `eda_processed/` for processed data (see `stage2-checklist.md`). With `--label <column>` the label is recorded in `external_label_counts.csv` and, after processing, in `external_labels.csv` keyed by `source_row_id`. It is never added to `processed_data.csv`.

Outputs are written to a staging directory, validated, and only then moved to the output path; a failure or PAUSE leaves no partial files. Output paths resolve against the project working directory, must be new or empty, and may not be inside the Skill directory.

## Notes
KNN in v0.4 is a baseline custom deterministic implementation using donor-column standardization and Euclidean distance on jointly observed predictors, based on the original (non-imputed) data. Rows with no usable predictors or donors trigger the pauses above. When fewer than k donors exist, all available donors are used and the count is logged. It is not a validated general-purpose imputation method; include a sensitivity warning. Imputed values are not sampled, and imputation uncertainty is not represented.
