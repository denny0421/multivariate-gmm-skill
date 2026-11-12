# Claude Code workflow handoff and approval gates — v1.4

| Interaction step | Hair stage(s) | Approval gate | Required execution artifact |
|---|---|---|---|
| 1. Read-only profile | 1–2 | Clarify only missing objective/feature semantics | data profile |
| 2. Question-specific exploration | 1–3 | Need user decision for transformations, excluded rows or method scope | EDA + stage1–3 checklist |
| 3. Approve spec | 1–3 / 4A | **Must establish user approval before fit** | approved_spec.json + approval note |
| 4. Compute via validated R | 4A–4D | No silent change of model family or data | fit status, model comparison, selected model |
| 5. Explain and qualify | 5 | No invented numeric outcomes; ask before subjective group names if necessary | interpretation and plots |
| 6. Validate + export | 6 | Optional holdout/resampling or new dataset processing needs approved plan | validation and reproducibility manifest |

## Outcome semantics

`PASS`: adequate for current stage; `WARNING`: proceed only with visible caveat and prior approval when needed; `PAUSE`: user decision or missing artifact blocks next action; `STOP`: current model/analysis cannot proceed; `FAILED`: single EM start or candidate fit failed, not entire workflow. In Stage 6 use `VALIDATED WITH LIMITATIONS` or `INCONCLUSIVE` alongside these statuses rather than misleading binary truth claims.

## Minimal terminal deliverables (future implementation)

- `approved_spec.json` (source file hash, variable list, n/p, transformations, G, seed, settings and approvals)
- `fit_status.csv`, `model_selection.csv`, `selected_model.rds`, `loglik_history.csv`
- `parameters.csv`, `posterior_probabilities.csv`, `classification.csv`, `component_summary.csv`
- `uncertainty_summary.json`, `restart_stability.csv`, `model_sensitivity.csv`
- `interpretation.md`, `validation.md`, and reproducible `analysis.qmd` / `reproduce.R` (planned)
- `session_info.txt`, warning log and file manifest

These are planned contract names only, for Stage 4–6. As of v1.4, executable and tested scripts exist for Stage 2 (profiling, EDA, missing-data handling) and Stage 3 (feasibility, approved specification); see `SKILL.md`.

**Authoritative status and artifact definitions:** see [`stage-contract.md`](stage-contract.md). For density-only objectives, cluster profiling and class-naming are optional rather than required. All optional validation not executed must be marked `NOT_RUN`.
