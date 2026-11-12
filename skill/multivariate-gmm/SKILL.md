---
name: multivariate-gmm
description: 使用高斯混合模型（Gaussian Mixture Model, GMM）進行多變量資料分群分析。逐步引導資料匯入、缺失值處理、分析設定、EM 模型估計、BIC/AIC 選模、分群解釋及模型驗證，並產生完整的繁體中文統計報告。適用於 CSV 資料分析與 GMM clustering。
---

# Multivariate GMM statistical analysis

## Status
Implemented in R:
- Data import (v0.1, `scripts/data_import.R`): read-only preview and user-confirmed import to a standardized CSV, before a workflow exists.
- Stage 2 (v0.6): data profiling, exploratory data analysis (EDA), missing-data diagnostics, and user-approved complete-case, mean, median and KNN handling.
- Stage 3 (v0.1): assumption and feasibility checks for a full-covariance GMM.
- Stage 4A–4B (v0.1, `scripts/em_stage4.R`): base-R EM for a full-covariance GMM, with multi-start initialisation, convergence and degeneracy checks, and per-G fits.

- Stage 4C–4D (v0.1, `scripts/select_stage4.R`): convergence diagnostics across starts (with label alignment), and BIC/AIC model selection over the approved G candidates.

- Stage 4 convergence confirmation (v0.1, `scripts/confirm_stage4.R`): optional, diagnostic-only strict continuation of every valid start; it never replaces a model.

- Warnings and limitations registry (v0.1, `scripts/warnings_registry.R`): carries diagnostics, user-approved limitations and analyst notes to the final report, bound to the data, spec and model.

- Stage 5 (v0.1, `scripts/interpret_stage5.R`): interpretation of the selected model. Covers parameter tables, back-transformation to original units, posterior classification and uncertainty, generic figures and a report.

- Stage 6 (v0.1, `scripts/validate_stage6.R`): validation and profiling.
  - 6A multi-start stability, with an optional replay of the same approved seeds;
  - 6B sensitivity of the selected vs alternative G, using saved parameters;
  - 6C post-hoc external validation (ARI, NMI, cross-tables);
  - 6D profiles and an optional descriptive strata check.

- Integration (v0.1):
  - `scripts/workflow.R` runs Stages 1–6 in order, with a state file and approval gates;
  - `scripts/report_final.R` writes the final Markdown report from the stage outputs, without re-estimating anything.

**Not implemented:** bootstrap/subsampling stability, missing-data EM, multiple imputation and other covariance families. Never claim a selected model or a component is "correct" or a verified group.

**This copy is the Cowork release (R >= 4.1).** The statistics, thresholds, decision tree and approval gates are those of the approved Skill. Only two things differ: SHA-256 hashes come from `scripts/hash_utils.R` (R >= 4.5: `tools::sha256sum()`; older R: the system `sha256sum`, or `shasum -a 256`; never MD5), and `scripts/check_env.R` checks the environment. The development tests are not included.

## Getting started (any environment, including Claude Cowork)
When the user provides a data file (CSV) and asks to use multivariate-gmm, or asks for a GMM / model-based clustering of it, follow these steps in order. The user never has to type a command; you run them and show the results.

1. **Locate the Skill.** `S` is the folder that contains this `SKILL.md` (the path it was loaded from). If the environment variable `CLAUDE_SKILL_DIR` is set and `$CLAUDE_SKILL_DIR/SKILL.md` exists, you may use it. Do not assume `.claude/skills/...`, `/mnt/skills/...` or any other fixed location. Confirm with `ls "$S/scripts/workflow.R"` before continuing.
2. **Choose the working folder.** All outputs go to a working folder: in Cowork, the folder the user selected; otherwise the current project folder. Run every command from there; outputs go to `results/<name>` under it. Never write into `$S` (the scripts refuse it) and never modify the user's data file.
3. **Check the environment.** Run `command -v Rscript`. If it exists, run `Rscript "$S/scripts/check_env.R"`. It checks R >= 4.1, `jsonlite`, the PNG device and SHA-256 (with known answers) and prints `Outcome:`.
4. **If R or jsonlite is missing**, stop and ask the user before installing anything. Say what will be installed and from where. Install only after their explicit yes, and only from the official Ubuntu package sources. On Ubuntu/Debian (check `/etc/os-release`) the command is:
   `sudo apt-get update && sudo apt-get install -y --no-install-recommends r-base-core r-cran-jsonlite`.
   Then run `check_env.R` again. If installation or the check fails, stop and show the full error. Never change network allowlists or security settings, never add third-party package sources, never switch to Python or another tool, and never write your own statistical code instead.
5. **Run the analysis** with the standard path below: `preview → import → new-run`, then Stages 2–6 with `workflow.R`. Stop at every gate exactly as described in this file; `--approved true` is passed only after the user's explicit approval in the conversation.

## Guiding the user (one decision at a time)
Assume the user does not know GMM, EM or BIC, and reply in the user's language. These rules change only how you talk; every gate, threshold and refusal in this file stays as it is.
- **Ask only the decision needed now.** The import settings (header, separator, encoding, missing-value markers) may be confirmed together as one short list. Statistical decisions are asked one after another, in the order of the table below. Never list later stages' parameters in advance.
- **One or two plain sentences per option:** what it does and what it costs. Explain a term the first time it is needed (see the terms below).
- **Options are a numbered text list**; the user may answer with the number or in words. Do not call them buttons. If the app offers a question tool you may use it, but the text must stand on its own.
- **Never decide for the user** the missing-data method, k, scaling, the independence answer, the G range, a model switch or a replay. Show a recommendation only when a script printed one (for example S3-06 recommends z-score), and say it is the program's recommendation. If the user says "you decide", restate the trade-off and ask again.
- **Record each decision.** Restate it in one line (for example "Recorded: complete-case."). Pass the user's own words to `--approval-ref` or `--independence-note` where the command takes them. Then run the next command yourself.
- **Run every command yourself**; report a few key numbers, the warnings and the folder written, in plain language. Show a command only if the user asks.
- **Outcomes, in plain words.**
  - Exit 0 (SUCCESS): the step finished. If its status is WARNING, say that the analysis can continue, name each limitation in one sentence, and say that the report keeps it. A warning never skips or shortens an approval.
  - Exit 2 (AWAITING_USER_APPROVAL): ask the question it names.
  - Exit 3 (BLOCKED): explain why the data cannot be analysed this way, and offer only the options it lists.
  - Exit 4 (REFUSED): say which earlier step or approval is missing.
  - Exit 1 (ERROR): show the error and stop.

Decision points, in order:

| # | When | Ask | Options | Then |
|---|---|---|---|---|
| 1 | R or jsonlite missing | permission to install | install from the official Ubuntu sources / do not install (stop) | apt, `check_env.R` |
| 2 | after `preview` | file format | header, separator, encoding, missing-value markers as seen in the preview: confirm or correct | `import` |
| 3 | after `import` | the goal | clustering (look for subgroups) / density (describe the shape of the data) | — |
| 4 | — | variables and roles | the numeric columns to model; the column of known groups kept for the end, if any | `new-run` (propose a short analysis name from the file name) |
| 5 | `stage2` exit 2 | missing values | the five methods of the missing-data menu (step 4 below); KNN also needs k | `stage2-handle` |
| 6 | after `stage2-handle` | go on to Stage 3 | continue / look at the processed data first | `stage3` (check) |
| 7 | `stage3` exit 2 | in this order: scaling, then row independence, then the G range; then the whole specification for approval | z-score / original units; independent / working assumption plus a short note / not independent (BLOCKED); G 1–5 or another range | `stage3 ... --approved true` |
| 8 | after `stage4` | accept the BIC choice | continue / show the details / plan a sensitivity analysis (its own approval) | `stage5` |
| 9 | after `stage5` | go on to validation | continue / review | — |
| 10 | before `stage6` | compare another G | the alternative Stage 4 named (for example the AIC choice) / none | `stage6 [--compare-g]` |
| 11 | after `stage6` | optional replay | run it (settings shown) / skip | `stage6-replay`, `stage6` |
| 12 | before `report` | report language (asked only here, never at the start) | 繁體中文 (recommended default) / English; one sentence each: same numbers and warnings, only the wording differs | `report --lang zh-TW` or `--lang en`; restate the choice in one line; give the full path of `report/final_report.md` and list the other files |

Terms, one sentence each:
- **GMM:** describes the data as a mixture of several bell-shaped (normal) groups, each with its own centre, spread and share.
- **EM:** estimates those groups by repeated small improvements; different starting points can end at different answers.
- **BIC / AIC:** scores that balance fit against complexity; smaller is better, and BIC prefers simpler models.
- **Posterior probability:** how strongly the model assigns a row to each group; not proof of the true group.
- **Standardisation (z-score):** puts variables on one scale so that a variable with large units does not dominate.
- **Independent rows:** each row is a separate unit, not a repeated measurement of the same one.
- **ARI:** agreement between the model's groups and known groups, checked only after fitting (1 = identical, about 0 = chance).

## Importing data and starting an analysis (standard path for new data)
Do these before any workflow exists: `preview → import → new-run`. `D="$S/scripts/data_import.R"` and `W="$S/scripts/workflow.R"`, with `S` from "Getting started".

```
Rscript $D preview --input <file> --encoding UTF-8 [--header true|false] [--sep comma|semicolon|tab|pipe] [--na "?,NA,<blank>"]
Rscript $D import  --input <file> --analysis <name> --header true|false [--names a,b,c | --names-file names.txt] --sep comma --encoding UTF-8 --na "?" --approval-ref "<the user's words>" --approved true
Rscript $W new-run --analysis <name> --import-record results/<name>/imports/<import_id>/import_record.json --columns a,b,c --objective clustering [--objective-text "..."] [--label x] --approval-ref "<the user's words>" --approved true
Rscript $W runs --analysis <name>
```

1. **Preview** writes and converts nothing. `--encoding` is required, and the header and missing-value markers are never guessed: without `--header` the first line is shown as data. `--na` here only simulates. Show the user the size, columns, types, marker counts, first rows and warnings. A warning about numeric values mixed with text usually means an undeclared marker.
2. **Ask the user** for the header, separator, encoding, the exact markers (`--na`, or `none`; `<blank>` and `<whitespace>` name those cells) and any column names. Only then run `import`.
3. **Import** keeps every value verbatim and writes `standardized.csv` plus `import_record.json` to `results/<name>/imports/<import_id>/`. The source file is never changed. The record holds the source and output SHA-256, the settings, conversions per column, the row, column, name and type checks, the cell-by-cell comparison and the R version.
   - **PAUSE `IMPORT_UNDECLARED_MISSING_LIKE`** (exit 2, nothing written): cells that are blank, only spaces or the text `NA` were not declared, and later stages would read them as missing. Ask the user; never add them to `--na` on your own.
   - Duplicate, empty or unusable names, rows of different lengths, invalid encoding and bad settings stop with an error. Do not edit the source file to get past one.
4. **Ask the user** to confirm the analysis variables, roles and objective. Only then run `new-run`. It verifies both hashes, creates a unique `results/<name>/runs/<run_id>/`, and prints that folder and the Stage 2 command. Tell the user the folder. Repeating an analysis means another `new-run`; nothing is reused or overwritten.

The rest of the workflow is unchanged: pass the run folder as `--root`. `init` remains for existing analyses and CSV files already in standard form. It does not record an import.

## Integrated workflow (use this first)
One analysis = one root directory (`results/<name>`) holding `workflow_state.json`. Each command runs **one** stage and reads the previous stage's outputs from the state, so never ask the user to locate files. A command never starts the next stage; it prints `Next:`. Run from the working folder (see "Getting started"):

```
W="$S/scripts/workflow.R"
Rscript $W init   --root results/<name> --input data/<file>.csv --columns a,b,c --objective clustering \
                  --objective-text "<user's research question>" [--label <external label column>] [--data-source data/SOURCE.md]
Rscript $W stage2 --root results/<name>
Rscript $W stage2-handle --root results/<name> --method complete-case|mean|median|knn|diagnostics-only [--k 5] [--all-missing-action drop] --approved true
Rscript $W stage3 --root results/<name> [--g 1:5]
Rscript $W stage3 --root results/<name> --g 1:5 --scale zscore|none --rows-independent true|assumed --independence-note "..." --approved true
Rscript $W stage4 --root results/<name>
Rscript $W models --root results/<name>                                     # list registered models and which one is active
Rscript $W register-model --root results/<name> --stage4-dir <select_stage4.R output>        # adds a candidate; active model unchanged
Rscript $W activate-model --root results/<name> --model-id <id> --approved true              # only after explicit user approval
Rscript $W sensitivity-status --root results/<name>                         # read-only: active settings, convergence, plans, candidates
Rscript $W confirm-convergence --root results/<name> [--model-id <id>] --approved true        # diagnostic only; re-executes EM
Rscript $W sensitivity-plan --root results/<name> [--n-starts 100] [--tol 1e-8] [--max-iter 5000] [--seed 421] [--g 2:5] [--init kmeans|random|random-soft|ward]       # shows differences and workload; exit 2; ward needs --n-starts 1
Rscript $W sensitivity-run --root results/<name> --plan <plan_id> --approval-ref "<user's approval>" --approved true
Rscript $W sensitivity-close --root results/<name> --plan <plan_id> --decision keep-active|withdraw --approval-ref "<user's decision>" --approved true
Rscript $W stage5 --root results/<name>
Rscript $W stage6 --root results/<name> [--compare-g 4] [--strata data/<file>.csv --strata-columns site,year]
Rscript $W stage6-replay --root results/<name> --g 3,4 --approved true      # optional; then rerun stage6
Rscript $W report --root results/<name> [--title "..."] [--lang en|zh-TW]          # default en; the Skill asks the user and recommends zh-TW
Rscript $W status --root results/<name>
```

**Gates.** Present the results and wait for the user at each gate. `--approved true` may only be passed after the user explicitly approved that exact action in the conversation.

| After | Present to the user | Proceed only when |
|---|---|---|
| `new-run` (or `init`) | objective, features, ID and label roles (Stage 1) | the user confirms them |
| `stage2` | EDA and missingness (steps 2–3 below) | no missing values → user confirms Stage 2; missing values → the user picks from the menu (step 4) |
| `stage2-handle` | the processed-data summary; or the KNN PAUSE menu (exit code 2) | the user approves the method (`--approved true`); **diagnostics-only ends the workflow**: write the report and stop |
| `stage3` (first run) | the checks and outstanding decisions (scale: z-score recommended but not forced; independence; G) | the user decides and approves → rerun with the decisions and `--approved true` |
| `stage4` | convergence and BIC/AIC (steps 9–10) | the user confirms |
| `register-model` | the candidate's G, log-lik, BIC, AIC and settings beside the active model | the user approves switching to that model id (`activate-model --approved true`) |
| `sensitivity-plan` | the settings changed, the active and planned initialisation, the workload, whether the confirmation will run, any `max_iter` conflict (exit 2) | the user approves this plan (`sensitivity-run --approved true`) |
| `sensitivity-run` | the comparison with the active model and **every warning**, or BLOCKED with its options | the user decides: `activate-model --approved true` or `sensitivity-close --decision keep-active` |
| `stage5` | interpretation (step 11) | the user confirms |
| `stage6` | validation (step 12); propose `stage6-replay` with its settings if partition-level stability is wanted | the user approves the replay explicitly (`--approved true`) |
| `report` | report location and contents | — |

**Active approved model.** Every Stage 4 result in a workflow is a registered model with an id (`G<g>-<hash>`), its source, settings, G, log-lik, BIC, AIC and file hashes.
- The first `stage4` fit becomes active under the Stage 3 approval. Any other `select_stage4.R` output (for example a sensitivity fit) enters only as a **candidate**, through `register-model`.
- `stage5`, `stage6`, `stage6-replay` and `report` read **only the active model**, never the newest folder or the best BIC. Their outputs belong to that model; a model other than the first writes to folders carrying its id.
- `activate-model` needs `--approved true` and checks file integrity, the Stage 3 spec and the data. Earlier models and their outputs are kept and can be reactivated.
- After a switch, `report` refuses to run until Stage 5 and Stage 6 exist for the new active model. It also stops if Stage 4, 5 and 6 outputs come from different models or specs, including in hand-written manifests.

**Sensitivity analysis.** Use these commands for any refit with other numerical settings (`scripts/sensitivity_workflow.R`); calling `select_stage4.R` plus `register-model` remains possible but has no plan, approval record or confirmation.
- Two separate approvals. Approving a plan covers the fit, the diagnostic confirmation and registering a valid fit as a candidate. Changing the active model always needs its own `activate-model --approved true`; never activate because a candidate has the lower BIC.
- Only `--n-starts`, `--tol`, `--max-iter`, `--seed` and `--g` can change. `--g` must stay within the approved Stage 3 candidates. Initialisation, `min_effective_n` and `max_cov_condition` are those of the active model.
- Output: `<root>/sensitivity/<plan_id>/` with `plan.json`, `fit/`, `confirmation/` and `comparison/`. One plan may be open at a time.
- With tol above 1e-8 the confirmation runs. Otherwise it is `NOT_RUN`: say so, and never describe it as passed. `BETTER_OPTIMUM_HIDDEN` and `ORIGINAL_BEST_PREMATURE` stay warnings; a better solution enters only through a new plan.
- `max_iter` at or above `strict_max_iter` (5000) is disclosed in the plan. The approved 5000 is kept, and a start with no iterations left stays unconfirmed.
- Plan status is separate from a command's Outcome; see `references/stage-contract.md`. A plan shown as `RUNNING`, `FIT_COMPLETED` or `CONFIRMED` after the process ended was interrupted: report it as unfinished, then `sensitivity-close --decision withdraw` and a new plan. Runs are never resumed.
- `NO_NEW_CANDIDATE` means the fit reproduced a registered model's exact estimates. That is a result to report, not a failure.
- Workflows that predate the registry on disk allow only `sensitivity-status`.

The workflow refuses out-of-order commands, processing without approval, fitting without an approved Stage 3 spec, a second Stage 3 approval (a changed specification needs a new workflow), a replay without approval, and overwriting any existing directory. Complete-data and missing-data paths are both supported: with no missing values, Stage 3 reads the input directly (row numbers serve as IDs). External labels are optional; without them, 6C and report section 10 say "not performed".

The final report (`report/final_report.md`, plus `figures/`, `report_manifest.json` with checksums of every source file, and `pending_heuristics.csv`) has these sections:
1. Objectives
2. Data and EDA
3. Missing data
4. Assumptions
5. EM convergence
6. BIC/AIC
7. Interpretation
8. Uncertainty
9. Stability and sensitivity
10. External validation
11. Conclusions and limitations
12. Reproducibility
- Appendix A: pending heuristics
- Appendix B: data source

For analyses run module by module, write a manifest JSON and run `Rscript "$S/scripts/report_final.R" --manifest <file> --output <new dir>` (examples: `config/penguins-report.json`, `config/automobile-report.json`). Optional manifest fields:
- `model_source_note`: states where the model comes from (e.g. an approved sensitivity fit);
- `stage4_reference`: another Stage 4 directory, shown as a comparison table;
- `mclust_comparison`: output of `tests/validate_em_vs_mclust.R`, shown as reference only;
- `additional_limitations`: user-approved limitation text. Do not put statistics here that are not in the stage files.

**Pending heuristics.** Every threshold that is a project choice is listed in `references/pending-heuristics.md`, generated from the code, and in Appendix A of each report. Never present them as textbook rules.

## Stage-by-stage statistical guidance (what to present at each gate)
1. Establish the objective and select the continuous numeric modelling features. Distinguish IDs, external labels (e.g. known species or classes reserved for later validation) and other profiling variables. Read `references/decision-tree.md` (v1.4), `references/checklist.md` and `references/stage2-checklist.md`.
2. Run **one** Stage 2 command: `workflow.R stage2`, or the module `scripts/data_stage2.R --method diagnostics`. Pass `--label <column>` for any external label. Do not write ad-hoc analysis scripts: this command produces everything in `stage2-checklist.md`.
   - Missing-data diagnostics: NA/NaN/Inf counted separately, a pattern table, charts, and rows whose selected variables are **all** missing (`all_missing_source_rows`).
   - EDA (`eda/`): descriptive statistics, histograms with density, boxplots, a scatterplot matrix, Pearson/Spearman correlations with pairwise n and CIs, a heatmap, and collinearity checks (zero variance, rank, condition number, VIF).
   - Do not infer MCAR/MAR/MNAR from missing counts. Do not treat the missingness charts as the EDA.
3. Report the EDA and missingness results. Also report any `collinearity_flags`, skewness or multimodality, outliers and scale differences, without deleting anything.
4. If missing values exist, present **an actual user-choice menu or a numbered textual list** of: complete-case, mean, median, KNN and diagnostics-only.
   - For each option, describe the potential bias, the distributional distortion, and the sample loss under complete-case.
   - If all-missing rows exist, say before the choice that KNN cannot impute them. Also say that mean/median would turn those rows into artificial points at the centre of the data.
   - Multiple imputation and missing-data EM are not implemented; do not present them as executable options.
5. If a method other than diagnostics is chosen, request explicit approval before running `--approved true`. Preserve the original input. KNN requires a user-selected k (suggest 5, not a universal rule). Never treat Inf as missing.
   - **KNN PAUSE `KNN_ALL_MISSING_ROWS`** (exit code 2, nothing written): list the source rows and show the menu:
     - A. drop those rows and continue KNN (`--all-missing-action drop`);
     - B. cancel KNN and return to the missing-data menu;
     - C. diagnostics only.

     Never drop rows or switch to mean/median without the user's choice; wait for confirmation.
   - **KNN PAUSE `KNN_NO_VALID_NEIGHBORS`** (exit code 2, nothing written): report the listed row/variable cells and the reason for each, then offer: another method from the menu, revising `--columns`, or diagnostics only.
   - Processing reruns the EDA on the processed data (`eda_processed/`). Compare it with `eda/`.
   - Every KNN run also writes a donor audit (`knn_audit_*`; see `references/missing-data-menu.md`). Report any `FEWER_THAN_K` cells and boundary ties. For a finished KNN run, use `scripts/knn_audit.R replay` into a new folder.
6. Show the processed-data summary and the Stage 2 checklist status. Obtain a **second explicit confirmation** before beginning Stage 3.
7. If there are no missing values, still run step 2.
8. **Stage 3:** run `scripts/feasibility_stage3.R` on the complete data (Stage 2 `processed_data.csv`, or the input itself when nothing was missing). Follow `references/stage3-checklist.md` (S3-01 to S3-15).
   - Present the report. The first run is normally a PAUSE, with these outstanding decisions:
     - scale: z-score (recommended default) or original units;
     - objective: clustering or density;
     - row independence;
     - the G candidate set (default 1:5).
   - Explain every WARNING with its statistical reason. Never drop rows, variables or G candidates automatically.
   - After the user decides and approves the full specification, rerun with `--scale ... --objective ... --rows-independent true --approved true` into a new output directory. Only then are z-scored data written (`transformed_data.csv`, `transform_params.csv`).
9. **Stage 4A–4B:** only with an approved Stage 3 spec (`approved_for_fit = true`), run `scripts/em_stage4.R --input <transformed_data.csv> --spec <stage3_spec.json>` for G values within the approved candidates. Formulas are in `references/stage4-em-math.md`.
   - Report per-G convergence, the number of starts reaching the best optimum, distinct optima, failed starts with their reasons, and any flagged log-likelihood decreases.
   - Carry the Stage 3 warnings (e.g. the independence working assumption) into every report.
   - No covariance regularisation is applied. `NOT_CONVERGED`, `DEGENERATE`, `NUMERIC_ERROR` and `INVALID_START` runs are never used as optima.
10. **Stage 4C–4D:** run `scripts/select_stage4.R` with the same inputs. It fits every approved G (20 starts; G = 1 in closed form) and then:
    - groups starts into distinct optima after label alignment;
    - excludes any G without a valid fit;
    - computes BIC = −2ℓ + k_G log n and AIC = −2ℓ + 2k_G (smaller is better);
    - selects by BIC.

    Report:
    - whether AIC agrees;
    - the ΔBIC evidence (Kass & Raftery scale);
    - alternatives with ΔBIC ≤ 6, kept for Stage 6;
    - any **boundary** optimum (selected G = largest searched). Tell the user that extending the range needs a new Stage 3 approval, and never extend it automatically;
    - the diagnostic warnings.

    mclust reports BIC with the opposite sign.
11. **Stage 5:** run `scripts/interpret_stage5.R --stage4-dir <selection dir> --data <analysis matrix> --spec <stage3_spec.json> --transform <transform_params.csv>`. Omit `--transform` when the approved scale is `none`.
    - It never refits or re-selects. It verifies that the stored posterior is reproduced by the stored parameters, which detects any label switching.
    - It back-transforms with μ_o = m + Sμ_z and Σ_o = SΣ_zS, and checks that the posterior is invariant under this transformation.
    - It reports mixing proportion, effective n and MAP counts as separate quantities, plus U_j = 1 − max τ and normalised entropy (0 when G = 1).
    - It lists ambiguous rows (U > 0.10) without removing or reclassifying them.

    In your summary, describe components only from their parameters. Never name them with external labels. State that components are not necessarily real groups, and that posteriors are not verified accuracy. Carry the Stage 3 warnings and the BIC/AIC note (alternatives kept for Stage 6).
12. **Stage 6:** run `scripts/validate_stage6.R --stage4-dir ... --stage5-dir ... --data ... --spec ... --labels <external_labels.csv> [--label-column] [--compare-g] [--strata <file> --strata-columns a,b]`.
    - The external label is read **only here**, aligned by row ID (missing IDs, duplicates or mismatches are refused), and used only for post-hoc evaluation.
    - The selected and alternative models are evaluated from **saved** Stage 4 parameters. The script checks that they reproduce the saved log-likelihood; nothing is refitted.
    - G-vs-G structure is read from the cross-table (SPLIT / MIXED / KEPT), never from a forced 1:1 pairing.
    - Partition-level stability across starts needs per-start classifications, which Stage 4 does not save. Before running `--mode replay` (same approved seeds; refused unless it reproduces Stage 4 exactly; writes to a separate directory), list its settings and purpose and get the user's approval.
    - Bootstrap/subsampling is optional and needs its own approval.
    - Never re-select G because of the external labels. Matched agreement is a separate, descriptive figure.
    - A strata check (e.g. site/year) is descriptive and reported separately; a stratified refit needs approval.
13. **Report:** ask the report language first (decision point 12), then run `workflow.R report --lang zh-TW|en` (or `report_final.R --manifest ... --lang ...`).
    - The language changes only the report text and the `report_language` field of `report_manifest.json`. It never changes the Stage 3 spec, spec_hash, model IDs, the active model or any estimate. Both languages can be written for the same analysis, each to a new folder, without refitting.
    - The zh-TW report keeps all 12 sections and the appendices, keeps every code and the original English messages, and explains them in Chinese. Figures are still in English in this release; the Chinese report adds a Chinese caption and label list for each figure.
    - Every number must come from the stage files; never add statistics that are not in them.
    - Never delete earlier outputs. A new report goes to a new directory.
    - Do not manufacture analyses or skip approvals.

## CLI
Run from the **working folder** (see "Getting started"); relative paths resolve against the working directory. Output paths inside the Skill directory are refused. Exit codes follow the outcome contract in `references/stage-contract.md`: 0 SUCCESS, 1 ERROR, 2 AWAITING_USER_APPROVAL, 3 BLOCKED, 4 REFUSED. Treat 2 as a normal gate: present the options and wait. Treat 3 as a statistical or data judgement, never a program failure, and offer the options it lists; `--approved true` cannot bypass it.

| Setting | CLI | Config key | Default |
|---|---|---|---|
| Input CSV | `--input` | `input` | required |
| Feature columns | `--columns a,b,c` | `columns` (array or string) | required |
| Output directory (new or empty) | `--output` | `output` | required |
| Method | `--method` | `method` | `diagnostics` |
| KNN neighbours | `--k` | `k` | 5 |
| All-missing rows (KNN) | `--all-missing-action drop` | `all_missing_action` | none (PAUSE) |
| External label column | `--label` | `label` | none |
| EDA on/off | `--eda true/false` | `eda` | true |
| Settings file | `--config file.json` | — | — |
| User approval | `--approved true` | **not allowed** | false |

CLI values override the config. Approval is never stored in a config: pass it per run, only after the user approves.

```
# S = the folder that contains this SKILL.md (see "Getting started")
Rscript $S/scripts/data_stage2.R --input $S/example_data/missing.csv --columns x1,x2,x3 --output results/missing-profile
Rscript $S/scripts/data_stage2.R --config config/my-stage2.json                       # diagnostics + EDA
Rscript $S/scripts/data_stage2.R --config config/my-stage2.json --method complete-case --output results/my-cc --approved true
# missing.csv source row 129 is all-missing: KNN first pauses (exit 2); after the user picks option A:
Rscript $S/scripts/data_stage2.R --input $S/example_data/missing.csv --columns x1,x2,x3 --output results/missing-knn --method knn --k 5 --approved true --all-missing-action drop
```
(The regression tests are kept with the development copy of the Skill and are not part of this release.)
Example config:
```json
{"input": "data/my.csv", "columns": ["x1", "x2", "x3"], "label": "group", "output": "results/my-stage2"}
```
In PowerShell, quote comma lists: `--columns "x1,x2,x3"`.

## Outputs (one directory per run)
- `summary.json`, `run_config.json`, `preprocessing_log.json`.
- `variable_missing.csv`, `pattern_summary.csv`, `data_overview.txt`, `missingness_map.png`, `missing_rate.png`.
- `eda/`: `descriptive_stats.csv`, `distributions.png`, `boxplots.png`, `scatter_matrix.png`, `correlation_pearson.csv`, `correlation_spearman.csv`, `correlation_pairwise_n.csv`, `correlation_pairs.csv`, `correlation_heatmap.png`, `collinearity.json`, `eda_summary.json`.
- With `--label`: `external_label_counts.csv`.
- After approved processing:
  - `processed_data.csv` (with `source_row_id`; never contains the label);
  - `external_labels.csv` (`source_row_id` + label), when `--label` is given;
  - `eda_processed/`.

Output safety:
- All checks and processing run before anything is written.
- Files are produced in a hidden staging directory next to the output, validated, then moved into place.
- On failure or PAUSE the staging directory is removed, so the same `--output` can be reused.
- A non-empty output directory is never overwritten, and the input file is never modified.

## Stage 3 CLI
| Setting | CLI | Config key | Default |
|---|---|---|---|
| Input CSV (complete) | `--input` | `input` | required |
| Output directory (new or empty) | `--output` | `output` | required |
| Features | `--columns a,b,c` | `columns` | all numeric columns except the ID |
| ID column | `--id-column` | `id_column` | `source_row_id` if present, else the row number |
| Candidate G | `--g 1:5` or `1,2,4` | `g` | `1:5` |
| Scale | `--scale zscore\|none` | `scale` | undecided (PAUSE) |
| Objective | `--objective clustering\|density` | `objective` | undecided (PAUSE) |
| Independent rows | `--rows-independent true\|false\|assumed` | `rows_independent` | undecided (PAUSE); `assumed` = working assumption (WARNING) |
| Independence limitation | `--independence-note "..."` | `independence_note` | required with `assumed` |
| Settings file | `--config file.json` | — | — |
| Approval | `--approved true` | **not allowed** | false |

```
Rscript $S/scripts/feasibility_stage3.R --input results/my-cc/processed_data.csv --output results/my-stage3/check
Rscript $S/scripts/feasibility_stage3.R --input results/my-cc/processed_data.csv --output results/my-stage3/approved --scale zscore --objective clustering --rows-independent true --approved true
```
Outputs: `stage3_checks.json`, `stage3_checks.csv`, `stage3_report.md`, `stage3_spec.json` (`spec_hash`, `approved_for_fit`, `approval_id`), `candidate_feasibility.csv`, `variable_diagnostics.csv`, `outlier_screening.csv`, `run_config.json`; plus `transformed_data.csv` and `transform_params.csv` only after approved z-scoring. The output safety rules are the same as Stage 2.

## Stage 4A–4B CLI
| Setting | CLI | Config key | Default |
|---|---|---|---|
| Analysis matrix | `--input` | `input` | required (Stage 3 `transformed_data.csv`, or the original-unit data if scale = none) |
| Approved Stage 3 spec | `--spec` | `spec` | required; refused unless `approved_for_fit` |
| Output directory | `--output` | `output` | required (new or empty) |
| G values | `--g 1:3` | `g` | all approved candidates; must be a subset of them |
| Starts / seed | `--n-starts`, `--seed` | `n_starts`, `seed` | 20, 421 (start s uses seed + s − 1) |
| Convergence | `--tol`, `--max-iter` | `tol`, `max_iter` | 1e-6 relative, 1000 |
| Initialisation | `--init kmeans\|random\|random-soft\|ward` | `init` | kmeans |
| Degeneracy guards | `--min-effective-n`, `--max-cov-condition` | `min_effective_n`, `max_cov_condition` | p + 1, 1e10 |

**Initialisation.** k-means stays the default. In a workflow, `stage4` accepts only `kmeans` or `random`; `random-soft` and `ward` run only through a user-approved `sensitivity-plan`, one method per plan. All methods feed the same M-step, E-step and validity checks.
- `random-soft`: each row's responsibilities ~ Dirichlet(1,...,1) (project heuristic, pending review; not adjustable).
- `ward`: one deterministic start (`--n-starts 1`), ward.D2 on Euclidean distance in the approved row order; ties follow the row order, with no jitter.
- No method dominates. Random starts can reach higher likelihoods but spread over many local optima, and with few starts can do worse than k-means. Compare methods only under the same budget and report Ward separately as one start.
- A higher likelihood does not make a model more reliable, because the full-covariance likelihood is unbounded as a covariance collapses. Report it with the minimum effective n, condition number and minimum eigenvalue. A high condition number below the existing guard does not invalidate a fit.

The script checks the approval status, the features, the row count, the row-ID hash, and that the input is the approved z-scored matrix (or the MD5 for original units).

Outputs:
- `em_summary.json` (spec hash, approval ID, settings, per-G summary, carried warnings, "model selection: NOT PERFORMED");
- `fit_status.csv` (one row per G × start: status, iterations, log-lik, minimum effective n, minimum π, maximum covariance condition, log-lik decreases, reason, `init_method`, `init_detail`, `rng_kind`, minimum covariance eigenvalue);
- `loglik_history.csv`, `em_parameters.json` (best fit per G, fitted scale), `posterior_G<g>.csv` (τ, MAP, uncertainty, keyed by row ID), `em_report.md`, `run_config.json`.

mclust is used only for validation, by `tests/validate_em_vs_mclust.R`, `tests/test_em.R` and `tests/test_selection.R`.

## Stage 4C–4D CLI
`Rscript $S/scripts/select_stage4.R --config config/<name>-stage4-select.json`. It takes the same settings as the Stage 4A–4B CLI; `--g` defaults to all approved candidates.

Outputs:
- `model_comparison.csv`: per G — log-lik, k_G, BIC, AIC, ΔBIC/ΔAIC, evidence, valid starts, status counts, starts reaching the best, distinct optima, minimum π, minimum effective n, maximum covariance condition, warnings, eligibility, selection flags, Stage 6 alternatives.
- `convergence_diagnostics.csv`: per G × start — status, log-lik, iterations, optimum group, gap to best, aligned parameter differences, label permutation, PD flag, reason.
- `convergence_summary.json`: includes every threshold with its exact/heuristic type.
- `loglik_history.csv`, `loglik_histories.png`, `bic_aic.png`.
- `selected_model.json` / `.rds`: fitted scale.
- `posterior_selected.csv`, `all_models_parameters.json`, `selection_report.md`, `run_config.json`.

## Stage 4 convergence confirmation (optional, diagnostic only)
A valid start can stop on a plateau under the default tol = 1e-6. Tail quantities cannot reveal this, so `scripts/confirm_stage4.R` replays each `CONVERGED_VALID` start and continues it with the unchanged EM under a stricter tolerance. Rule and thresholds: `references/stage4-em-math.md`, `references/pending-heuristics.md` (items 37–40).

```
Rscript $S/scripts/confirm_stage4.R --stage4-dir <selection dir> --input <analysis matrix> --spec <stage3_spec.json> --output results/<new dir> [--g 5] [--strict-tol 1e-8] [--strict-max-iter 5000]
```

| Start classification | Meaning |
|---|---|
| `POSSIBLE_PREMATURE_STOP` | gain = strict − original log-lik ≥ 0.1. Never call it a statistically significant improvement. |
| `NO_MATERIAL_CHANGE` | gain < 0.1. Never claim that a local maximum was proven. `strict_role` says whether it stays below the strict best. |
| `STRICT_NOT_CONVERGED`, `STRICT_DEGENERATE`, `STRICT_NUMERIC_ERROR` | the strict continuation is inconclusive or invalid; excluded from the strict comparison |
| `REPLAY_MISMATCH` | the replay differs from the record in status, iterations or log-lik; not compared |
| `NOT_ELIGIBLE` | the original status was not `CONVERGED_VALID`; it is kept as recorded |
| `CLOSED_FORM_NOT_ITERATIVE` | G = 1: closed-form MLE, nothing to iterate |

G-level flags: `ORIGINAL_BEST_PREMATURE` (the original best start itself stopped early) and `BETTER_OPTIMUM_HIDDEN` (another start, once continued, exceeds the original best start's strict log-lik by at least 0.1). Checking only the best start would miss the second case.

Outputs: `confirmation_starts.csv`, `confirmation_by_G.csv` (original vs strict log-lik, ΔBIC at fixed G = −2Δℓ, BIC, AIC), `confirmation_summary.json` (preferred G before and after), `confirmation_report.md`, `run_config.json`.

The module does not read or write `workflow_state.json`, writes nothing into the Stage 4 directory and produces no `selected_model.rds`, so its output cannot be registered as a model. To adopt a better solution: fit it with `select_stage4.R` into a new directory, then run `workflow.R register-model` and, only after the user's explicit approval, `activate-model --approved true`.

It does not search for new starts, so it cannot find optima that no start reaches, and passing it does not establish a global maximum.

## Analysis warnings and limitations registry
`scripts/warnings_registry.R` keeps warnings and limitations apart from the approved spec and models, which it never edits. At any gate, run `list` and show the applicable items to the user. Rules: `references/stage-contract.md`.

| Class | Origin | How it is stored |
|---|---|---|
| `AUTO_DIAGNOSTIC` | computed from the stage outputs at report time | never written by hand; snapshot in the report folder |
| `USER_APPROVED_LIMITATION` | an approved spec note, or a confirmed record | write-once record |
| `ANALYST_NOTE` | an interpretation confirmed by the user; **never an established statistical result** | write-once record |

```
R=$S/scripts/warnings_registry.R
Rscript $R propose  --registry-dir results/<name>/warnings-registry --class ANALYST_NOTE --severity WARNING --stage 3 --code <id> --scope data|spec|model --text-file note.txt --stage2-dir <dir> [--stage3-dir <dir>] [--stage4-dir <dir>] --evidence ev.json --source-file <record> --source-locator "<where>"
Rscript $R approve  --registry-dir <dir> --candidate CAND-... --approval-ref "<the user's words>" --approved true
Rscript $R annotate <same options as propose> --approval-ref "..." --approved true
Rscript $R list     --registry-dir <dir> --stage2-dir <dir> [--stage3-dir <dir>] [--stage4-dir <dir>]
```

- **Show a new text to the user word for word first.** Use `propose` until the user confirms it, then `approve`. `annotate` is only for a text the user has already confirmed exactly. `--approved true` only after that confirmation, as for every other approval.
- Records are append-only: correct one with a new record and `--supersedes <id>`. Each must have a source and at least one evidence reference (`ev.json`: an array of items with `file`, `label`, and `path` (JSON), or `count_where`, or `field` with `where`/`row` (CSV); optional `expected`). Numbers shown in a report are read from the evidence file, not typed.
- Identity comes from the files, never from the text. Do not guess which model a note belongs to.
- `workflow.R report` reads `<root>/warnings-registry` when it exists; a manifest uses `"warnings_registry": "<dir>"`.
- Section 11 of the report separates automated diagnostics, user-approved limitations and analyst notes. It lists records not cited, by id and reason only. `additional_limitations` in a manifest appear in their own "not verified" section.
- Report stops: another dataset, analysis data or spec; a changed record, source or evidence file; a missing approval. A record bound to another model is excluded and listed, and the report continues.

No statistical check or threshold is added by the registry.

## Stage 5 CLI
| Setting | CLI | Config key |
|---|---|---|
| Stage 4 selection directory | `--stage4-dir` | `stage4_dir` (needs `selected_model.rds`, `posterior_selected.csv`, `selected_model.json`, `model_comparison.csv`) |
| Analysis matrix | `--data` | `data` |
| Approved Stage 3 spec | `--spec` | `spec` |
| Transform parameters | `--transform` | `transform` (required if scale = zscore; refused if scale = none; must match the spec) |
| Output directory | `--output` | `output` |
| Ambiguity threshold | `--ambiguity-threshold` | `ambiguity_threshold` (default 0.10, heuristic) |

Outputs:
- `stage5_summary.json`, `component_summary.csv` (π, effective n, MAP count/proportion, mean U/entropy, ambiguous count);
- `component_means.csv` (original and fitted scale), `component_sd_original.csv`, `component_covariances.csv` (original and fitted covariance, correlation);
- `stage5_parameters_original.json`, `classification.csv` (τ, MAP, U, entropy, ambiguous flag), `ambiguous_observations.csv`, `uncertainty_summary.json`;
- figures: `mean_profile_original.png`, `mean_profile_standardized.png`, `proportions_map.png`, `uncertainty.png`, `correlation_heatmaps.png`, `pca_projection.png` (visualisation only);
- `stage5_report.md`, `run_config.json`.

## Stage 6 CLI and outputs
Settings: `--stage4-dir`, `--stage5-dir`, `--data`, `--spec`, `--labels`, `--label-column` (default: the only non-ID column), `--compare-g` (default: the AIC choice plus BIC alternatives; when there are none the report states "No alternative G was compared" and Stage 6 completes normally), `--replay-dir`, `--strata`, `--strata-columns`, `--output`, `--config`. Replay mode: `--mode replay --g 3,4 --output <new dir>` (writes `start_partitions.csv`, `replay_check.csv`, `replay_info.json`).

Outputs. Generic file names are used, since the label need not be "species"; this mapping replaces the originally requested names:

| Requested name | Generic name |
|---|---|
| `component_species_table.csv` | `component_label_table.csv` |
| `component_species_heatmap.png` | `component_label_heatmap.png` |

Full list:
- `stability_summary.csv`;
- only with `--replay-dir`: `stability_partitions_ari.csv` (ARI of each start to the best start), `stability_pairwise_ari.csv` (all start pairs), `stability_within_optimum_ari.csv` and `stability_between_optima_ari.csv`. Near-best (best optimum group) and all-valid summaries are kept separate.

Replay seeds: Stage 4 gives each start its own seed (start s uses `seed + s − 1`, via `set.seed` inside `with_seed`). Replay reuses `em_fit_gmm()` with the Stage 4 `run_config.json`. It refuses to write anything unless every start's status and log-likelihood match `convergence_diagnostics.csv`.
- `model_sensitivity.csv`, `crosstab_selected_vs_G<g>.csv`;
- `component_label_table.csv` (counts, row and column proportions, for the selected and alternative models), `external_validation.json` (ARI, NMI, tables, matched agreement and its mapping);
- `cluster_profiles.csv` (post-hoc label columns only with external labels; `substantive_interpretation`), `strata_check.csv` (optional), `stage6_summary.json`;
- figures: `stability_plot.png`, `component_label_heatmap.png`, `model_sensitivity_plot.png`;
- `stage6_report.md`, `run_config.json`.

## References
- `references/pending-heuristics.md`: all unreviewed heuristic thresholds and project choices, generated from the code.
- `references/stage4-em-math.md`: verified EM formulas, convergence, validity checks and initialisation.
- `references/stage3-checklist.md`: Stage 3 rules S3-01 to S3-15, with PASS/WARNING/PAUSE/STOP criteria and statistical reasons.
- `references/decision-tree.md` (v1.4): the authoritative statistical decision tree.
- `references/decision-tree-alignment.md`: resolved and still-pending differences between the specification and the implemented Stage 2/3 behaviour.
- `references/stage2-checklist.md`: Stage 2 items D01–D05 (data, missingness) and E01–E08 (EDA, collinearity, scale), with evidence files.
- `references/missing-data-menu.md`: missing-data choice policy and caveats.
- `references/stage-contract.md`: workflow states and approval handoff; the estimation contracts are pending.
- `references/stage4-model-fitting.md`, `references/stage5-interpretation.md`, `references/stage6-validation.md`: planned methods; not callable implementations.
- Source: Hair et al., *Multivariate Data Analysis*, 8th ed., Chapter 4, six-stage clustering decision framework, used as a reference framework and extended for GMM (not identical to Hair). Missing-data handling specifics and EDA screening thresholds are project design choices, not textbook prescriptions.
