# Stage Contracts and State Machine — v1.4

This file is authoritative for workflow execution state.
- Stage 2 (`data_stage2.R`, `eda_stage2.R`) and Stage 3 (`feasibility_stage3.R`) are implemented and covered by automated tests.
- The Stage 4–6 contracts below remain future implementation contracts, not claims of tested functionality.

## Decision versus computation statuses

**Gate status:** `PASS` = can proceed; `WARNING` = can proceed with disclosed issue when previously approved; `PAUSE` = requires user action/approval; `STOP` = requested configuration invalid. `PAUSE` and `STOP` cannot be bypassed by the AI.

**Fit start status:** `CONVERGED_VALID`, `FAILED_START`, `NOT_CONVERGED`, `DEGENERATE`, `NUMERIC_ERROR`. A candidate `G` has `VALID_CANDIDATE` only if at least one start is `CONVERGED_VALID`; otherwise it is `FAILED_CANDIDATE`. **Workflow:** `STOP_NO_VALID_MODELS` only if no valid candidate remains; otherwise failures are retained as warnings in the selection report.

**Validation coverage:** `CHECKS_COMPLETE_WITH_LIMITATIONS` / `INCONCLUSIVE` / `STOP`. Optional validations each have `COMPLETED`, `NOT_RUN`, or `FAILED`, recorded separately. Neither completed mandatory checks nor optional checks demonstrate the Gaussian mixture is true.

## Outcome contract (CLI)

`workflow.R`, `data_stage2.R`, `data_import.R`, `feasibility_stage3.R` and `select_stage4.R` end with machine-readable lines: `Outcome`, `Exit-Code`, `Stage`, `Code`, `Next-Action`.

| Outcome | Exit | Meaning | Examples |
|---|---|---|---|
| `SUCCESS` | 0 | Completed. A WARNING is a success that must be disclosed | stage completed, Diagnostics Only, cancelled |
| `AWAITING_USER_APPROVAL` | 2 | A normal gate; output is complete and a decision is needed | Stage 2 missing-data menu, KNN PAUSE, Stage 3 decisions, import PAUSE |
| `BLOCKED` | 3 | A statistical or data judgement: this request cannot be estimated | Stage 3 STOP, Inf, no valid model |
| `ERROR` | 1 | The program or its input failed | bad argument, missing file, unexpected failure |
| `REFUSED` | 4 | Not allowed now; nothing ran | wrong order, missing approval, changed or mismatched files |

`--approved true` cannot turn BLOCKED into SUCCESS.

`workflow_state.json` holds `gate` (`outcome`, `stage`, `code`, `reason`, `options`, `time`), updated by SUCCESS, AWAITING_USER_APPROVAL and BLOCKED. A SUCCESS replaces an earlier pause; `report` leaves it unchanged. ERROR and REFUSED do not write the state. `history` keeps every step. A workflow without `gate` remains readable.

Recovery depends on the reason:

| Reason | Recovery |
|---|---|
| Stage 3 STOP on candidate G | rerun `stage3` in the same workflow with smaller `--g` |
| Stage 3 STOP on independence | confirm the design; rerun `stage3` only if the user can justify it or accepts a working assumption |
| Constant, dependent or invalid variables; Inf | new run with other `--columns`, or corrected data |
| Stage 4 no valid model | rerun `stage4` with other numerical settings into a new folder; changing G needs a new run and Stage 3 approval |

`cancel --reason "..." --approved true` ends an active workflow. All files and approvals stay; analysis commands are then refused.

The state file is written to a temporary file, verified and then replaced in one step. If replacement fails, the previous file is kept and the command ends in ERROR. Leftover `.workflow_state.tmp-*` files are never read as state, and `status` reports them.

## Immutable data and approvals

The approved spec uniquely binds: input file checksum; selected row IDs and column names; missingness handling and transformation (and learned parameters); objective `clustering|density`; candidate G; full covariance model; numerical settings; random start schedule; output requirements; user approval (time/interaction reference where possible). Calculate `spec_hash` from a canonical serialized spec; never change the specification silently. If changed, return to `PAUSE` and request approval.

## Model registry and active approved model (`workflow.R`)

`workflow_state.json` holds `models` (one entry per registered Stage 4 output) and `active_model_id`.

| Field | Content |
|---|---|
| `model_id` | `G<g>-<first 12 hex of the selected_model.rds hash>` |
| `status` | `active`, `candidate` or `inactive` |
| `origin`, `dir` | `stage4` (workflow's first fit) or `registered`; the Stage 4 output directory |
| `G`, `loglik`, `BIC`, `AIC`, `k_G` | from `selected_model.json` |
| `settings` | tol, max_iter, seed, n_starts, init, best start and its seed |
| `spec_hash`, `approval_id`, `spec_file`, `data_file` | Stage 3 approval, with hashes of the spec and the analysis data |
| `files` | hashes of the seven required Stage 4 files |
| `stage5`, `stage6`, `replay` | outputs produced **for this model** |

Rules:
- A candidate must match the approved spec hash and analysis data at registration.
- Activation needs explicit user approval and a passing integrity check. The same check runs before Stages 5–6, replay and the report.
- Stages 5–6 and the report read only the active model.
- `report_final.R` stops if Stage 4, 5 and 6 outputs do not share one lineage and one spec.
- Workflows created before the registry are converted in memory on read; read-only commands do not write the state file.

## Sensitivity analysis (`sensitivity_workflow.R`)

`plan.json` records the initialisation (`settings.init`, `init_spec`, `rng_kind`). A run is refused when the plan file changed, the recorded definition no longer matches the method, or the random number generator differs; a fit that did not use the planned method is not registered.

A plan's **lifecycle** is separate from a command's **Outcome**. `st$sensitivity$plans[[id]]` holds `status`, `lifecycle` (each transition with its step and time), `steps` (`fit`, `confirmation`, `comparison`, `registration`, `close`), `plan_sha256` and `candidate_model_id`.

| Plan status | Meaning |
|---|---|
| `PLANNED` | Written and awaiting approval; nothing fitted |
| `RUNNING` | Approved; the fit has not been recorded |
| `FIT_COMPLETED` | Fit recorded, with hashes of its files |
| `CONFIRMED` | The confirmation ran and was recorded. It does **not** mean it passed: see `steps$confirmation$result` (`NO_FLAGS`, `WARNING`, `INCOMPLETE`). Skipped when the result is `NOT_RUN` |
| `CANDIDATE_REGISTERED` | Validated and registered as a candidate; the active model is unchanged |
| `NO_NEW_CANDIDATE` | Valid, but its parameters and log-likelihood equal a registered model's; nothing registered |
| `BLOCKED` | No valid model; nothing registered |
| `FAILED` | An error stopped a step; `lifecycle` names it and completed outputs stay |
| `CLOSED_KEEP_ACTIVE`, `WITHDRAWN` | Closed by the user; no file or candidate is removed |

| Command result | Outcome | `gate` code |
|---|---|---|
| Plan created | AWAITING_USER_APPROVAL (2) | `SENSITIVITY_PLAN_APPROVAL` |
| Run started (state only, seen after an interruption) | not printed | `SENSITIVITY_RUN_UNFINISHED` (AWAITING_USER_APPROVAL) |
| Candidate registered | AWAITING_USER_APPROVAL (2) | `ACTIVE_MODEL_DECISION` |
| Identical model | SUCCESS (0) | `NO_NEW_CANDIDATE` |
| No valid model | BLOCKED (3) | `STOP_NO_VALID_MODELS` |
| A step failed | ERROR (1), or REFUSED (4) for an integrity failure | `SENSITIVITY_RUN_FAILED` (AWAITING_USER_APPROVAL) |
| Plan closed | SUCCESS (0) | `SENSITIVITY_KEEP_ACTIVE`, `SENSITIVITY_WITHDRAWN` |
| Bad value / not allowed before anything ran | ERROR (1) / REFUSED (4) | unchanged, state not written |

Once a run has started, an ERROR or REFUSED does record the plan's `FAILED` status and gate. This is the one exception to "ERROR and REFUSED do not write the state": otherwise a stale approval gate would remain. `confirm-convergence` records its result without changing the gate, so it cannot replace a pending decision. `wf_next` derives pending plan actions from the plan records.

A run re-verifies the plan file hash, plan ID, active model id and file hashes, spec hash, approval id, spec file, data file and approved G. It stops if any differs and refuses existing output folders. Fit hashes are checked again before the confirmation and before registration.

Before registration a candidate must have: at least one `CONVERGED_VALID` start at the selected G, with the selected start among them; complete parameters that pass `em_check` (positive definite, conditioning, effective n); a log-likelihood reproduced within the Stage 5 rule; a complete posterior reproduced within the Stage 5 tolerance; log-lik, BIC, AIC and k_G equal to the computed values within `replay_match_abs` in both `selected_model.json` and `model_comparison.csv`; and the approved spec hash and data. No new threshold is introduced.

Interruption: each output is committed atomically and each step is recorded after it. A plan left in an unfinished status reports what is recorded and what is on disk but unrecorded. Runs are not resumed; withdraw it (files stay) and create a new plan, which uses a new folder.

## Data import and analysis folders (`data_import.R`, `workflow.R new-run`, `runs`)

```
results/<analysis>/imports/<import_id>/   standardized.csv, import_record.json
results/<analysis>/runs/<run_id>/         workflow_state.json and every stage output of that run
```

- `import_id` = `I-YYYYMMDD-HHMMSS-NN`; `run_id` = `R-YYYYMMDD-HHMMSS-NN`. A folder that exists is never reused.
- `preview` writes nothing. Header, encoding and missing-value markers are never guessed.
- `import` needs `--approved true` and `--approval-ref`. Files are parsed as text and cells are written verbatim; only cells declared in `--na` change, and they become `NA`.
- A cell that is blank, only spaces or the text `NA` and was not declared causes PAUSE `IMPORT_UNDECLARED_MISSING_LIKE`, because Stages 2-6 read `NA` and blank as missing.
- `import_record.json`: source SHA-256 and MD5, settings, names source, conversions per column, standardized SHA-256, validation (rows, columns, names and order, types as Stage 2 reads them, and the cell comparison), approval, R version.
- The cell comparison separates identical text, equal numbers written differently (`88.60` and `88.6`), real differences and missing-value mismatches. An import passes only with no real difference, mismatch or reformatted number.
- `new-run` needs `--approved true` and `--approval-ref`, verifies the source and standardized hashes, and records the import id, hashes, variables, objective and approval in `workflow_state.json` (`run`, `import`, `approvals`).

## Warnings and limitations registry (`warnings_registry.R`)

Warnings are never added by editing a spec or a model. Records sit in an analysis-specific directory (`<root>/warnings-registry`), one write-once file each; candidates sit in `candidates/` and are never cited.

| Field | Content |
|---|---|
| `id`, `class`, `severity`, `stage`, `code`, `scope` | `class`: `USER_APPROVED_LIMITATION` or `ANALYST_NOTE` (`AUTO_DIAGNOSTIC` is computed at report time); `severity`: INFO, WARNING, LIMITATION; `scope`: data, spec, model |
| `input_md5`, `analysis_data_md5` | raw input and approved analysis data |
| `spec_hash`, `approval_id` | spec and model scopes |
| `model_id` | model scope: `G<g>-<first 12 hex of selected_model.rds hash>` |
| `text` | verbatim; never generated or rewritten by the module |
| `source`, `evidence` | file, sha256, locator; evidence values are read at report time |
| `approved` | by, reference to the user's confirmation, time |
| `supersedes`, `from_candidate`, `content_sha256` | corrections; origin; hash over all the fields above |

Applicability:

| Condition | Result |
|---|---|
| Different input or analysis data | STOP the report |
| Different spec hash or Stage 3 approval | STOP the report |
| Changed content, source or evidence file; no approval | STOP the report |
| Model scope, different active model | excluded; id and reason listed, content not reproduced |
| Superseded, or a candidate awaiting confirmation | excluded; id and reason listed, content not reproduced |

## Input/output handoff

| Stage | Required input | Output contract | Gate |
|---|---|---|---|
| 1 Objective | User question, optional file | `objective`, observation unit, feature roles, `row_id` plan | PASS / PAUSE / STOP |
| 2 Design | Stage 1, read-only file | Data profile: n,p, column type/NA/NaN/Inf, row IDs, planned processing | PASS / PAUSE / STOP |
| 3 Assumptions | Proposed design | Feasibility and risks, checklist statuses, approved config + `approval_id`, `spec_hash` | PASS or no fit |
| 4 Model fitting | Exact approved spec and transformed matrix | `fit_status.csv` one row per G/start; valid candidate table; selected model with `model_id`; likelihood history; parameters; posterior | Valid models available or STOP |
| 5 Interpretation | Selected valid model + exact row IDs | Component descriptive table and posterior diagnostics; branch by `objective` | PASS / WARNING / PAUSE / STOP |
| 6 Validation | Stage 4 outputs, Stage 5 description | Stability, comparison sensitivity, numeric reproducibility, optional coverage flags, qualified report | CHECKS_COMPLETE_WITH_LIMITATIONS / INCONCLUSIVE / STOP |

## Required selection-table columns (future)

`G, covariance, n, p, k, best_start_id, loglik, AIC, BIC, fit_status, warning_codes, model_id, spec_hash`. Failed candidates have NA for numeric information criteria and cannot win selection. Distinguish nonconverged from degenerate fits; do not rank untrusted fits.

## Required posterior-table columns (future)

`spec_hash, model_id, row_id, MAP_component, max_posterior, uncertainty, tau_1 ... tau_G`. Check row count, unique IDs, component count, finite probabilities, range and sum-to-one tolerance. Pure density objective may still output posterior diagnostics but need not interpret them as classes.

## Reproducibility contract (future)

`approved_spec.json`, source-data checksum, `reproduce.R` (or `.qmd`), code revision/hash, R `sessionInfo()`, deterministic seed/start registry, full warning log and artifact manifest. Do not label a result `reproducible` without exercising a clean rerun test.
