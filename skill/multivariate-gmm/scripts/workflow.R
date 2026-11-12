#!/usr/bin/env Rscript
# Workflow orchestrator for the multivariate-gmm Skill (Stages 1-6 + final report).
# One analysis = one root directory with workflow_state.json. Each command runs ONE stage, reads the previous
# stage's outputs from the state (no manual file hunting), and enforces the approval gates:
#   - missing-data processing needs --approved true (diagnostics-only ends the workflow);
#   - fitting needs an approved Stage 3 spec (--approved true there);
#   - a replay needs --approved true;
#   - nothing chains automatically: the next command is reported, never run.
# --approved true must only be passed after the user has explicitly approved in the conversation.
# Usage: Rscript workflow.R <command> --root results/<name> [--key value ...]
# Imported data: data_import.R preview, data_import.R import, then new-run (creates results/<name>/runs/<run_id>); runs lists them.
# Commands: new-run, runs, init, stage2, stage2-handle, stage3, stage4, register-model, activate-model, models, stage5, stage6, stage6-replay, report, status,
#           sensitivity-status, confirm-convergence, sensitivity-plan, sensitivity-run, sensitivity-close (see sensitivity_workflow.R)
# Model registry: every Stage 4 result is a registered model (id, source, settings, file hashes). Stages 5-6, replay and the
# report read ONLY the active model, and their outputs are stored per model. A registered candidate becomes active only through
# activate-model --approved true, after integrity, Stage 3 spec and data checks.
suppressPackageStartupMessages(library(jsonlite))

wf_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
WF_DIR <- dirname(wf_script_path())
if (!exists('skill_sha256', inherits = TRUE)) source(file.path(WF_DIR, 'hash_utils.R'), local = TRUE) # Cowork release: SHA-256 on R >= 4.1
source(file.path(WF_DIR, 'feasibility_stage3.R'), local = TRUE)
source(file.path(WF_DIR, 'select_stage4.R'), local = TRUE)
source(file.path(WF_DIR, 'validate_stage6.R'), local = TRUE)
source(file.path(WF_DIR, 'report_final.R'), local = TRUE)
source(file.path(WF_DIR, 'sensitivity_workflow.R'), local = TRUE)
WF_VERSION <- '0.2.0'
WF_STATE <- 'workflow_state.json'
WF_MODEL_FILES <- c('selected_model.rds', 'selected_model.json', 'posterior_selected.csv', 'model_comparison.csv',
                    'all_models_parameters.json', 'convergence_diagnostics.csv', 'run_config.json')

# ---------------------------------------------------------------- state
wf_now <- function() format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC')
wf_read <- function(root) {
  f <- file.path(resolve_path(root), WF_STATE)
  if (!file.exists(f)) fail('No workflow found at ', resolve_path(root), ' - run "init" first.')
  st <- tryCatch(jsonlite::fromJSON(f, simplifyVector = FALSE), error = function(e) fail('workflow_state.json is unreadable or incomplete at ', f, '; it may come from an interrupted write. It was not changed.')) # keep lists (history/approvals) as lists
  st$columns <- unlist(st$columns); st$stages$stage3$runs <- unlist(st$stages$stage3$runs); st$stages$report <- unlist(st$stages$report)
  wf_migrate(st)
}

# ---------------------------------------------------------------- model registry
wf_hash <- function(f) unname(skill_sha256(f)) # SHA-256 only; a missing file gives NA, which never matches a recorded hash

# Builds a registry entry from a Stage 4 output directory; refuses incomplete output or output from another spec or data file.
wf_model_entry <- function(st, dir, origin) {
  a <- st$stages$stage3$approved
  wf_require(!is.null(a), 'Registering a model needs an approved Stage 3 specification.')
  dir <- resolve_path(dir)
  miss <- WF_MODEL_FILES[!file.exists(file.path(dir, WF_MODEL_FILES))]
  if (length(miss)) fail('Stage 4 directory is incomplete (', paste(miss, collapse = ', '), '): ', dir)
  sj <- jsonlite::fromJSON(file.path(dir, 'selected_model.json'), simplifyVector = TRUE)
  rd <- readRDS(file.path(dir, 'selected_model.rds')); rc <- jsonlite::fromJSON(file.path(dir, 'run_config.json'), simplifyVector = TRUE)
  if (!identical(sj$spec$spec_hash, a$spec_hash) || !identical(rd$spec_hash, a$spec_hash)) refuse('Spec hash mismatch: this Stage 4 output was not fitted under the approved Stage 3 specification (', a$spec_hash, ').')
  if (!identical(sj$input$md5, unname(tools::md5sum(a$data)))) refuse('Data mismatch: this Stage 4 output was not fitted on the approved analysis data.')
  if (is.null(sj$selected_G) || is.na(sj$selected_G) || !identical(as.numeric(sj$selected_G), as.numeric(rd$G))) fail('Stage 4 output has no consistent selected model.')
  hashes <- as.list(setNames(vapply(file.path(dir, WF_MODEL_FILES), wf_hash, character(1), USE.NAMES = FALSE), WF_MODEL_FILES))
  list(model_id = sprintf('G%d-%s', as.integer(sj$selected_G), substr(hashes[['selected_model.rds']], 1, 12)), origin = origin, dir = dir,
       G = sj$selected_G, loglik = sj$loglik, BIC = sj$BIC, AIC = sj$AIC, k_G = sj$k_G,
       settings = list(tol = rc$tol, max_iter = rc$max_iter, seed = rc$seed, n_starts = rc$n_starts, init = rc$init, best_start = sj$best_start, best_start_seed = sj$seed),
       spec_hash = a$spec_hash, approval_id = a$approval_id, spec_file = list(path = a$spec, sha = wf_hash(a$spec)), data_file = list(path = a$data, sha = wf_hash(a$data)),
       files = hashes, registered_utc = wf_now())
}

# Integrity of a registered model: its files, the approved spec file and the analysis data must all be unchanged.
wf_verify_model <- function(st, m) {
  for (f in names(m$files)) {
    p <- file.path(m$dir, f)
    if (!file.exists(p)) refuse('Integrity check failed for model ', m$model_id, ': missing ', p)
    if (!identical(wf_hash(p), m$files[[f]])) refuse('Integrity check failed for model ', m$model_id, ': file changed since registration: ', p)
  }
  if (!identical(wf_hash(m$spec_file$path), m$spec_file$sha)) refuse('Integrity check failed for model ', m$model_id, ': the Stage 3 spec file changed: ', m$spec_file$path)
  if (!identical(wf_hash(m$data_file$path), m$data_file$sha)) refuse('Integrity check failed for model ', m$model_id, ': the analysis data changed: ', m$data_file$path)
  invisible(TRUE)
}
wf_active <- function(st) {
  id <- st$active_model_id
  if (is.null(id) || is.null(st$models[[id]])) fail('No active approved model is recorded for this workflow.')
  st$models[[id]]
}
wf_use_active <- function(st) { m <- wf_active(st); wf_verify_model(st, m); m }
# The first fit keeps the standard folder names; any other model gets folders carrying its id.
wf_model_out <- function(st, m, base) if (identical(m$origin, 'stage4')) wf_new_dir(st$root, base) else wf_new_dir(st$root, paste0(base, '-', m$model_id))
wf_store_model <- function(st, m) { st$models[[m$model_id]] <- m; st }

# Older workflows have no registry: build it in memory from their single Stage 4 fit. It reaches disk only if a later command writes the state.
wf_migrate <- function(st) {
  s4 <- st$stages$stage4
  if (!is.null(st$models) || is.null(s4) || is.null(st$stages$stage3$approved) || is.null(s4$selected_G) || is.na(s4$selected_G)) return(st)
  m <- wf_model_entry(st, s4$dir, 'stage4'); m$status <- 'active'; m$activated_by <- 'legacy workflow: its only Stage 4 fit'
  m$stage5 <- st$stages$stage5; m$stage6 <- st$stages$stage6; m$replay <- st$stages$stage6_replay
  st$models <- setNames(list(m), m$model_id); st$active_model_id <- m$model_id
  st
}
# The state file is replaced in one step: the old file stays until a complete, verified new one takes its place.
wf_tmp_pattern <- '^\\.workflow_state\\.tmp-'
wf_write <- function(st, rename = file.rename) {
  st$updated_utc <- wf_now(); st$next_action <- wf_next(st)
  f <- file.path(st$root, WF_STATE); tmp <- tempfile('.workflow_state.tmp-', tmpdir = st$root); on.exit(unlink(tmp))
  jsonlite::write_json(st, tmp, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null', digits = NA)
  chk <- tryCatch(jsonlite::fromJSON(tmp, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(chk) || !identical(chk$root, st$root)) fail('Could not write workflow state: the new file failed verification. The previous state was kept.')
  h <- unname(tools::md5sum(tmp))
  if (!isTRUE(suppressWarnings(rename(tmp, f)))) fail('Could not update workflow state: the file could not be replaced. The previous state was kept.')
  if (!identical(unname(tools::md5sum(f)), h)) fail('Could not verify the updated workflow state: its content differs from what was written.')
  invisible(st)
}
wf_interrupted_writes <- function(root) list.files(root, pattern = wf_tmp_pattern, all.files = TRUE)
# A SUCCESS gate replaces any earlier PAUSE; a report does not change what the workflow is waiting for.
wf_gate <- function(st, outcome, stage, code, reason = NULL, options = NULL) { st$gate <- list(outcome = outcome, stage = stage, code = code, reason = reason, options = options, time = wf_now()); st }
wf_log <- function(st, command, result) {
  st$history[[length(st$history) + 1L]] <- list(time = wf_now(), command = command, result = result)
  if (identical(command, 'report')) st else wf_gate(st, 'SUCCESS', command, as.character(result))
}
wf_require_open <- function(st) wf_require(!identical(st$status, 'cancelled'), 'This workflow was cancelled; its files are kept, but it cannot continue.')
# Recovery depends on which check stopped the specification.
wf_stage3_recovery <- function(ids) {
  rec <- c(`S3-01` = 'Correct non-numeric or invalid values in the source, then import it again and create a new run.',
           `S3-03` = 'Remove the constant variable: create a new run with other --columns.',
           `S3-04` = 'Remove the linearly dependent variable: create a new run with other --columns.',
           `S3-09` = 'Review the near-singular covariance: create a new run with other --columns or data.',
           `S3-11` = 'Rerun stage3 in this workflow with smaller candidates in --g.',
           `S3-14` = 'Check the study design. Only if the user can justify it, rerun stage3 with --rows-independent true, or assumed with --independence-note; otherwise a dependence-aware method is needed.')
  o <- unique(unname(rec[intersect(ids, names(rec))]))
  if (length(o)) o else 'Review the STOP checks in stage3_report.md and revise the request.'
}
wf_new_dir <- function(root, base) { d <- file.path(root, base); k <- 2L; while (dir.exists(d)) { d <- file.path(root, sprintf('%s-%d', base, k)); k <- k + 1L }; d }
wf_require <- function(cond, msg) if (!isTRUE(cond)) refuse(msg)

wf_next <- function(st) {
  s <- st$stages
  if (identical(st$status, 'finished-diagnostics-only')) return('report (the workflow ended after diagnostics only)')
  if (identical(st$status, 'cancelled')) return('none: this workflow was cancelled; its files are kept')
  if (is.null(s$stage2)) return('stage2 (profiling, EDA and missing-data diagnostics)')
  if (isTRUE(s$stage2$has_inf)) return('STOP: Inf/-Inf present - correct the input and start a new workflow')
  if (is.null(s$stage2$decision)) {
    p <- if (!is.null(st$last_pause)) paste0(' [last PAUSE: ', st$last_pause$code, ']') else ''
    return(paste0('USER CHOICE: stage2-handle --method complete-case|mean|median|knn|diagnostics-only (processing needs --approved true)', p))
  }
  if (is.null(s$stage3$approved) && identical(st$gate$outcome, 'BLOCKED') && identical(st$gate$stage, 'stage3')) return(paste0('BLOCKED at Stage 3; approval cannot bypass a STOP. Options: ', paste(unlist(st$gate$options), collapse = ' / ')))
  if (is.null(s$stage3$approved)) return('stage3: present the checks; after the user decides scale / row independence / G and approves, rerun with --approved true')
  if (is.null(s$stage4)) return('stage4 (EM fits for all approved G + BIC/AIC selection)')
  if (identical(s$stage4$status, 'STOP_NO_VALID_MODELS')) return(paste0('STOP: no valid model. Options: ', paste(unlist(st$gate$options), collapse = ' / ')))
  sn <- wf_sens_next(st); if (!is.null(sn)) return(sn)
  m <- if (is.null(st$active_model_id)) NULL else st$models[[st$active_model_id]]
  if (is.null(m$stage5)) return(sprintf('stage5 (interpretation of active model %s)', m$model_id))
  if (is.null(m$stage6)) return(sprintf('stage6 (validation of active model %s; optional stage6-replay needs --approved true)', m$model_id))
  'report (final integrated report)'
}

# ---------------------------------------------------------------- commands
wf_init <- function(root, input, columns, objective, objective_text = NULL, label = NULL, data_source = NULL) {
  root <- resolve_path(root)
  if (path_within(root, STAGE2_SKILL_ROOT)) fail('Workflow root must be outside the Skill directory (e.g. results/<name>).')
  if (file.exists(file.path(root, WF_STATE))) refuse('A workflow already exists at', root, '. Use another root; existing analyses are never overwritten.')
  if (dir.exists(root) && length(list.files(root, all.files = TRUE, no.. = TRUE))) refuse('Workflow root must be new or empty:', root)
  if (!objective %in% c('clustering', 'density')) fail('objective must be clustering or density.')
  inp <- resolve_path(input); if (!file.exists(inp)) fail('Input not found: ', inp)
  cols <- trimws(strsplit(columns, ',', fixed = TRUE)[[1]])
  hdr <- names(read.csv(inp, nrows = 1, check.names = FALSE, fileEncoding = 'UTF-8-BOM'))
  if (length(cols) < 2 || any(!cols %in% hdr)) fail('Provide at least two existing feature columns.')
  if (!is.null(label) && (!label %in% hdr || label %in% cols)) fail('The label must be an existing column that is not a feature.')
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  st <- list(workflow_version = WF_VERSION, name = basename(root), root = root, created_utc = wf_now(), status = 'active',
             input = list(path = inp, md5 = unname(tools::md5sum(inp))), columns = cols, label = label, objective = objective,
             objective_text = objective_text, data_source = if (is.null(data_source)) NULL else resolve_path(data_source),
             stages = list(stage1 = list(objective = objective, objective_text = objective_text, features = cols, external_label = label,
                                         note = 'Stage 1 record: objective and variable roles as stated by the user')),
             approvals = list(), history = list())
  st <- wf_log(st, 'init', 'workflow created'); wf_write(st)
  list(status = 'OK', message = sprintf('Workflow created at %s.', root), next_action = wf_next(st))
}

# A new, independent analysis folder for imported data: results/<name>/runs/<run_id>. Existing runs are never reused.
wf_new_run <- function(analysis, import_record, columns, objective, objective_text = NULL, label = NULL, data_source = NULL, results_dir = 'results', approved = FALSE, approval_ref = NULL) {
  if (!isTRUE(approved)) refuse('A new run requires the user\'s confirmation of the analysis variables and objective: pass --approved true only after the user confirmed them.')
  if (is.null(approval_ref) || !nzchar(trimws(approval_ref))) fail('A new run needs --approval-ref (the user\'s confirmation).')
  if (is.null(analysis) || !grepl('^[A-Za-z0-9][A-Za-z0-9_.-]*$', analysis) || grepl('..', analysis, fixed = TRUE)) fail('analysis must be a simple name (letters, digits, "_", "-", "."), not a path.')
  if (is.null(import_record)) fail('--import-record is required.')
  rf <- resolve_path(import_record); if (!file.exists(rf)) fail('Import record not found: ', rf)
  r <- jsonlite::fromJSON(rf, simplifyVector = TRUE)
  if (!identical(r$record_type, 'data_import')) fail('Not an import record: ', rf)
  if (!identical(r$analysis, analysis)) fail('This import belongs to analysis "', r$analysis, '", not "', analysis, '".')
  std <- file.path(dirname(rf), r$standardized$file); if (!file.exists(std)) fail('Standardized file not found: ', std)
  if (!identical(wf_hash(std), r$standardized$sha256)) refuse('The standardized file changed since import:', std)
  if (!file.exists(r$source$path) || !identical(wf_hash(r$source$path), r$source$sha256)) refuse('The source file is missing or changed since import:', r$source$path)
  d <- read.csv(std, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''), fileEncoding = 'UTF-8-BOM')
  cols <- trimws(strsplit(columns, ',', fixed = TRUE)[[1]])
  if (length(cols) < 2 || anyDuplicated(cols) || any(!cols %in% names(d))) fail('Provide at least two distinct, existing feature columns.')
  nn <- cols[!vapply(d[cols], is.numeric, NA)]; if (length(nn)) fail('Selected columns are not numeric after import: ', paste(nn, collapse = ', '), '. Review them in the preview; a new import may be needed.')
  parent <- file.path(resolve_path(results_dir), analysis, 'runs')
  if (path_within(parent, STAGE2_SKILL_ROOT)) fail('Results must be outside the Skill directory.')
  dir.create(parent, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), '%Y%m%d-%H%M%S', tz = 'UTC'); k <- 1L
  repeat { id <- sprintf('R-%s-%02d', stamp, k); root <- file.path(parent, id); if (dir.create(root, showWarnings = FALSE)) break; k <- k + 1L }
  res <- tryCatch(wf_init(root, std, columns, objective, objective_text, label, data_source), error = function(e) { if (!length(list.files(root, all.files = TRUE, no.. = TRUE))) unlink(root, recursive = TRUE); stop(e) })
  st <- wf_read(root); st$run <- list(analysis = analysis, run_id = id, columns = I(cols), objective = objective)
  st$import <- list(record = rf, record_sha256 = wf_hash(rf), import_id = r$import_id, source = r$source, standardized_sha256 = r$standardized$sha256)
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = paste('analysis variables and objective confirmed for run', id), ref = approval_ref)
  st <- wf_log(st, 'new-run', id); wf_write(st)
  list(status = 'CREATED', message = sprintf('Run %s created. All outputs of this analysis go to:\n%s', id, root), next_action = sprintf('Rscript workflow.R stage2 --root %s', root), output = root)
}

wf_runs <- function(analysis, results_dir = 'results') {
  if (is.null(analysis) || !grepl('^[A-Za-z0-9][A-Za-z0-9_.-]*$', analysis) || grepl('..', analysis, fixed = TRUE)) fail('analysis must be a simple name, not a path.')
  parent <- file.path(resolve_path(results_dir), analysis, 'runs')
  ds <- if (dir.exists(parent)) sort(list.dirs(parent, recursive = FALSE)) else character()
  if (!length(ds)) return(list(status = 'NONE', message = sprintf('No runs under %s.', parent), next_action = 'new-run'))
  rows <- vapply(ds, function(d) tryCatch({ st <- wf_read(d); sprintf('%s [%s] input md5 %s; active model %s; next: %s; root %s', basename(d), st$status, st$input$md5, if (is.null(st$active_model_id)) 'none' else st$active_model_id, wf_next(st), d) }, error = function(e) sprintf('%s [unreadable: %s]', basename(d), conditionMessage(e))), '')
  list(status = 'OK', message = paste(c('', rows), collapse = '\n'), next_action = 'use --root <root> with the stage commands')
}

wf_stage2 <- function(root) {
  st <- wf_read(root)
  wf_require(identical(st$status, 'active'), 'Workflow is not active.')
  wf_require(is.null(st$stages$stage2), 'Stage 2 diagnostics already done for this workflow.')
  out <- file.path(st$root, 'stage2-diagnostics')
  r <- analyze(st$input$path, paste(st$columns, collapse = ','), out, 'diagnostics', label = st$label)
  st$stages$stage2 <- list(dir = out, missing_cells = r$missing_cells, infinite_cells = r$infinite_cells, has_missing = r$missing_cells > 0,
                           has_inf = r$infinite_cells > 0, all_missing_rows = r$all_missing_source_rows,
                           decision = if (r$missing_cells == 0 && r$infinite_cells == 0) 'not-needed' else NULL)
  st <- wf_log(st, 'stage2', r$status)
  if (r$infinite_cells > 0) st <- wf_gate(st, 'BLOCKED', 'stage2', 'INVALID_VALUES_INF', sprintf('%d Inf/-Inf cell(s) in the selected variables; they are invalid, not missing.', r$infinite_cells),
                                          list('Correct or remove these values in the source, then import it again and create a new run.', 'Create a new run with --columns that exclude the affected variables.'))
  else if (r$missing_cells > 0) st <- wf_gate(st, 'AWAITING_USER_APPROVAL', 'stage2', 'MISSING_DATA_CHOICE', sprintf('%d missing cell(s): the user must choose how to handle them.', r$missing_cells),
                                              list('stage2-handle --method complete-case --approved true', 'stage2-handle --method mean --approved true', 'stage2-handle --method median --approved true', 'stage2-handle --method knn --k <k> --approved true', 'stage2-handle --method diagnostics-only'))
  wf_write(st)
  list(status = r$status, message = sprintf('Missing cells %d, Inf %d, all-missing rows %d.', r$missing_cells, r$infinite_cells, r$all_missing_row_count),
       next_action = wf_next(st), output = out)
}

wf_stage2_handle <- function(root, method, k = 5L, all_missing_action = NULL, approved = FALSE) {
  st <- wf_read(root)
  wf_require(identical(st$status, 'active'), 'Workflow is not active.')
  wf_require(!is.null(st$stages$stage2), 'Run stage2 first.')
  wf_require(isTRUE(st$stages$stage2$has_missing), 'There are no missing values to handle.')
  wf_require(is.null(st$stages$stage2$decision), sprintf('Missing-data handling already decided (%s).', st$stages$stage2$decision))
  if (identical(method, 'diagnostics-only')) {
    st$stages$stage2$decision <- 'diagnostics-only'; st$status <- 'finished-diagnostics-only'
    st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = 'missing-data choice: diagnostics only')
    st <- wf_gate(wf_log(st, 'stage2-handle', 'diagnostics-only'), 'SUCCESS', 'stage2', 'DIAGNOSTICS_ONLY_CHOSEN'); wf_write(st)
    return(list(status = 'FINISHED', message = 'Diagnostics only: no data changed; the workflow ends here (a report can still be generated).', next_action = wf_next(st)))
  }
  if (!isTRUE(approved)) refuse('Missing-data processing requires the user\'s explicit approval: pass --approved true only after the user approved this method.')
  out <- file.path(st$root, paste0('stage2-', method))
  r <- tryCatch(analyze(st$input$path, paste(st$columns, collapse = ','), out, method, approved = TRUE, k = k, all_missing_action = all_missing_action, label = st$label),
                stage2_pause = function(e) e)
  if (inherits(r, 'stage2_pause')) {
    st$last_pause <- list(code = r$code, message = conditionMessage(r), time = wf_now())
    st <- wf_gate(wf_log(st, 'stage2-handle', paste('PAUSE', r$code)), 'AWAITING_USER_APPROVAL', 'stage2', r$code, strsplit(conditionMessage(r), '\n', fixed = TRUE)[[1]][1],
                  if (identical(r$code, 'KNN_ALL_MISSING_ROWS')) list('stage2-handle --method knn --k <k> --all-missing-action drop --approved true', 'stage2-handle with another method', 'stage2-handle --method diagnostics-only')
                  else list('stage2-handle with another method (complete-case, mean or median)', 'a new run with other --columns', 'stage2-handle --method diagnostics-only'))
    wf_write(st)
    return(list(status = 'PAUSE', message = conditionMessage(r), next_action = wf_next(st)))
  }
  st$last_pause <- NULL
  st$stages$stage2$decision <- 'processed'
  st$stages$stage2$processing <- list(dir = out, method = method, k = if (method == 'knn') k else NULL, all_missing_action = all_missing_action,
                                      rows_retained = r$rows_retained, rows_removed = r$rows_removed)
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = paste('missing-data processing approved:', method))
  st <- wf_log(st, 'stage2-handle', r$status); wf_write(st)
  list(status = r$status, message = sprintf('%s: %d rows retained, %d removed.', method, r$rows_retained, r$rows_removed), next_action = wf_next(st), output = out)
}

wf_stage3_input <- function(st) {
  s2 <- st$stages$stage2
  wf_require(!is.null(s2), 'Run stage2 first.')
  wf_require(!isTRUE(s2$has_inf), 'Inf/-Inf present: estimation is blocked.')
  wf_require(!is.null(s2$decision), 'Missing values need a decision from the missing-data menu first (stage2-handle).')
  wf_require(!identical(s2$decision, 'diagnostics-only'), 'The workflow ended with diagnostics only.')
  if (identical(s2$decision, 'processed')) list(data = file.path(s2$processing$dir, 'processed_data.csv'), id = 'source_row_id')
  else list(data = st$input$path, id = NULL)
}

wf_stage3 <- function(root, g = '1:5', scale = NULL, rows_independent = NULL, independence_note = NULL, approved = FALSE) {
  st <- wf_read(root)
  wf_require(identical(st$status, 'active'), 'Workflow is not active.')
  wf_require(is.null(st$stages$stage3$approved), 'Stage 3 is already approved; a different specification needs a new workflow.')
  inp <- wf_stage3_input(st)
  out <- wf_new_dir(st$root, 'stage3-check')
  r <- feasibility(inp$data, out, columns = st$columns, id_column = inp$id, g = g, scale = scale, objective = st$objective,
                   rows_independent = rows_independent, independence_note = independence_note, approved = isTRUE(approved))
  runs <- c(st$stages$stage3$runs, out)
  st$stages$stage3$runs <- runs
  if (isTRUE(r$approved_for_fit)) {
    st$stages$stage3$approved <- list(dir = out, spec = file.path(out, 'stage3_spec.json'), spec_hash = r$spec_hash, approval_id = r$approval_id,
                                      data = if (identical(scale, 'zscore')) file.path(out, 'transformed_data.csv') else inp$data,
                                      transform = if (identical(scale, 'zscore')) file.path(out, 'transform_params.csv') else NULL)
    st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = paste('Stage 3 specification approved:', r$approval_id))
  }
  st <- wf_log(st, 'stage3', r$status)
  if (identical(r$status, 'STOP')) {
    ids <- vapply(Filter(function(cn) identical(cn$status, 'STOP') && cn$id != 'S3-15', r$checks), `[[`, '', 'id')
    st <- wf_gate(st, 'BLOCKED', 'stage3', 'STAGE3_STOP', paste(unlist(r$outstanding_decisions), collapse = ' | '), as.list(wf_stage3_recovery(ids)))
  } else if (identical(r$status, 'PAUSE')) st <- wf_gate(st, 'AWAITING_USER_APPROVAL', 'stage3', 'STAGE3_DECISIONS_REQUIRED', 'Stage 3 needs the user\'s decisions.', as.list(as.character(r$outstanding_decisions)))
  else if (isTRUE(r$approved_for_fit)) st <- wf_gate(st, 'SUCCESS', 'stage3', 'APPROVED_FOR_FIT')
  wf_write(st)
  list(status = r$status, approved_for_fit = r$approved_for_fit, outstanding = r$outstanding_decisions, next_action = wf_next(st), output = out)
}

wf_stage4 <- function(root, n_starts = EM_DEFAULTS$n_starts, seed = EM_DEFAULTS$seed, tol = EM_DEFAULTS$tol, max_iter = EM_DEFAULTS$max_iter, init = EM_DEFAULTS$init) {
  st <- wf_read(root); a <- st$stages$stage3$approved
  wf_require(identical(st$status, 'active'), 'Workflow is not active.')
  wf_require(!is.null(a), 'Fitting needs an approved Stage 3 specification.')
  blocked_before <- identical(st$stages$stage4$status, 'STOP_NO_VALID_MODELS') # no model exists yet, so other numerical settings may be tried
  wf_require(is.null(st$stages$stage4) || blocked_before, 'Stage 4 already done for this workflow.')
  if (!init %in% EM_INIT_METHODS) fail('--init must be one of ', paste(EM_INIT_METHODS, collapse = ', '), ', received: ', init)
  wf_require(init %in% c('kmeans', 'random'), sprintf('init = %s is available only through a user-approved sensitivity-plan; the initial Stage 4 fit uses kmeans or random.', init))
  out <- wf_new_dir(st$root, 'stage4-selection')
  prev <- if (blocked_before) c(unlist(st$stages$stage4$previous_blocked_dirs), st$stages$stage4$dir) else NULL
  r <- stage4_select(a$data, a$spec, out, n_starts = n_starts, seed = seed, tol = tol, max_iter = max_iter, init = init)
  st$stages$stage4 <- list(dir = out, selected_G = r$selection$selected_G, status = r$selection$status, previous_blocked_dirs = if (length(prev)) as.list(prev) else NULL)
  if (!is.na(r$selection$selected_G)) {
    m <- wf_model_entry(st, out, 'stage4'); m$status <- 'active'; m$activated_by <- 'initial Stage 4 fit under the approved Stage 3 specification'; m$activated_utc <- wf_now()
    st$models <- setNames(list(m), m$model_id); st$active_model_id <- m$model_id
  }
  st <- wf_log(st, 'stage4', r$selection$status)
  if (identical(r$selection$status, 'STOP_NO_VALID_MODELS')) st <- wf_gate(st, 'BLOCKED', 'stage4', 'STOP_NO_VALID_MODELS', 'No candidate G has a valid converged fit.',
                                                                           list('Review convergence_diagnostics.csv, then rerun stage4 in this workflow with other numerical settings (--init random, --n-starts, --seed).', 'Change the candidate G: that needs a new run and a new Stage 3 approval.'))
  wf_write(st)
  list(status = r$selection$status, message = paste(r$selection$messages, collapse = ' '), next_action = wf_next(st), output = out)
}

wf_stage5 <- function(root, ambiguity_threshold = 0.10) {
  st <- wf_read(root); a <- st$stages$stage3$approved; s4 <- st$stages$stage4
  wf_require_open(st)
  wf_require(!is.null(s4) && isTRUE(!is.na(s4$selected_G)), 'Stage 5 needs a Stage 4 selected model.')
  m <- wf_use_active(st)
  wf_require(is.null(m$stage5), sprintf('Stage 5 already done for active model %s.', m$model_id))
  out <- wf_model_out(st, m, 'stage5-interpretation')
  r <- stage5_interpret(m$dir, a$data, a$spec, out, transform = a$transform, ambiguity_threshold = ambiguity_threshold)
  m$stage5 <- list(dir = out); st <- wf_store_model(st, m); if (identical(m$origin, 'stage4')) st$stages$stage5 <- m$stage5
  st <- wf_log(st, 'stage5', paste('done for', m$model_id)); wf_write(st)
  list(status = 'DONE', message = sprintf('Mean uncertainty %.4f; ambiguous rows %d.', r$summary$uncertainty$overall$mean_U, nrow(r$ambiguous)), next_action = wf_next(st), output = out)
}

wf_labels_file <- function(st) {
  if (is.null(st$label)) return(NULL)
  s2 <- st$stages$stage2
  if (identical(s2$decision, 'processed')) return(file.path(s2$processing$dir, 'external_labels.csv'))
  f <- file.path(st$root, 'stage6-labels', 'external_labels.csv') # derived file keyed by row number (= row_id of the unprocessed input)
  if (!file.exists(f)) {
    raw <- read.csv(st$input$path, check.names = FALSE, stringsAsFactors = FALSE)
    dir.create(dirname(f), showWarnings = FALSE)
    write.csv(setNames(data.frame(seq_len(nrow(raw)), raw[[st$label]]), c('row_id', st$label)), f, row.names = FALSE, na = '')
  }
  f
}

wf_stage6 <- function(root, compare_g = NULL, strata = NULL, strata_columns = NULL) {
  st <- wf_read(root); a <- st$stages$stage3$approved
  wf_require_open(st)
  wf_require(!is.null(st$active_model_id), 'Stage 6 needs Stage 5.')
  m <- wf_use_active(st)
  wf_require(!is.null(m$stage5), sprintf('Stage 6 needs Stage 5 for active model %s.', m$model_id))
  out <- wf_model_out(st, m, 'stage6-validation')
  rdir <- m$replay$dir
  r <- stage6_validate(m$dir, m$stage5$dir, a$data, a$spec, wf_labels_file(st), out,
                       label_column = st$label, compare_g = compare_g, replay_dir = rdir, strata = strata, strata_columns = strata_columns)
  m$stage6 <- list(dir = out, replay_used = !is.null(rdir), labels_used = !is.null(st$label)); st <- wf_store_model(st, m)
  if (identical(m$origin, 'stage4')) st$stages$stage6 <- m$stage6
  st <- wf_log(st, 'stage6', paste('done for', m$model_id)); wf_write(st)
  list(status = 'DONE', message = if (is.null(r$external)) 'No external labels: 6C not performed.' else sprintf('ARI %.4f, NMI %.4f (post hoc).', r$external$ARI, r$external$NMI),
       next_action = wf_next(st), output = out)
}

wf_stage6_replay <- function(root, g, approved = FALSE) {
  st <- wf_read(root); a <- st$stages$stage3$approved
  wf_require_open(st)
  wf_require(!is.null(st$stages$stage4), 'Replay needs Stage 4.')
  if (!isTRUE(approved)) refuse('A replay re-executes EM: list its settings to the user and pass --approved true only after explicit approval.')
  m <- wf_use_active(st)
  wf_require(is.null(m$replay), sprintf('A replay already exists for active model %s.', m$model_id))
  out <- wf_model_out(st, m, 'stage6-replay')
  r <- stage6_replay(m$dir, a$data, a$spec, out, g)
  m$replay <- list(dir = out, g = g); st <- wf_store_model(st, m)
  if (identical(m$origin, 'stage4')) st$stages$stage6_replay <- m$replay
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = paste('Stage 6 replay approved for G =', g, 'on model', m$model_id))
  st <- wf_log(st, 'stage6-replay', 'done'); wf_write(st)
  list(status = 'DONE', message = 'Replay reproduced Stage 4; rerun stage6 to include partition-level ARI.', next_action = 'stage6 (rerun to use the replay)', output = out)
}

wf_manifest <- function(st, title = NULL) {
  s <- st$stages
  m <- if (is.null(st$active_model_id)) NULL else st$models[[st$active_model_id]] # only the active model feeds the report
  list(title = title, name = st$name, objective = st$objective, objective_text = st$objective_text, columns = st$columns, label = st$label,
       input = st$input$path, data_source = st$data_source, stage2_diagnostics = s$stage2$dir,
       stage2_decision = if (is.null(s$stage2$decision)) 'undecided' else s$stage2$decision, stage2_processing = s$stage2$processing$dir,
       stage3_approved = s$stage3$approved$dir, stage4 = m$dir, stage5 = m$stage5$dir, stage6 = m$stage6$dir, stage6_replay = m$replay$dir,
       active_model_id = m$model_id, active_model = m[setdiff(names(m), c('stage5', 'stage6', 'replay'))],
       active_model_files = if (!is.null(m)) file.path(m$dir, names(m$files)) else NULL,
       config_files = file.path(st$root, WF_STATE),
       warnings_registry = if (dir.exists(file.path(st$root, 'warnings-registry'))) file.path(st$root, 'warnings-registry') else NULL)
}

wf_register_model <- function(root, stage4_dir) {
  st <- wf_read(root)
  wf_require_open(st)
  wf_require(!is.null(st$active_model_id), 'Registering a candidate needs a completed Stage 4 in this workflow.')
  m <- wf_model_entry(st, stage4_dir, 'registered')
  wf_require(is.null(st$models[[m$model_id]]), sprintf('Model %s is already registered.', m$model_id))
  m$status <- 'candidate'; st <- wf_store_model(st, m)
  st <- wf_log(st, 'register-model', m$model_id); wf_write(st)
  list(status = 'CANDIDATE', message = sprintf('Registered %s as a candidate (G = %s, log-lik %.4f, BIC %.3f). The active model is still %s.', m$model_id, m$G, m$loglik, m$BIC, st$active_model_id),
       next_action = sprintf('activate-model --model-id %s --approved true, only after the user explicitly approves the switch', m$model_id))
}

# Ends an unfinished workflow at the user's request. Every file and approval stays as it is.
wf_cancel <- function(root, reason, approved = FALSE) {
  st <- wf_read(root)
  if (!isTRUE(approved)) refuse('Cancelling a workflow requires the user\'s explicit approval: pass --approved true only after the user asked for it.')
  if (is.null(reason) || !nzchar(trimws(reason))) refuse('Cancelling needs --reason.')
  wf_require(identical(st$status, 'active'), sprintf('Only an active workflow can be cancelled (status: %s).', st$status))
  st$status <- 'cancelled'; st$cancelled <- list(time = wf_now(), reason = reason)
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = paste('workflow cancelled:', reason))
  st <- wf_gate(wf_log(st, 'cancel', reason), 'SUCCESS', 'cancel', 'CANCELLED_BY_USER', reason); wf_write(st)
  list(status = 'CANCELLED', message = 'Workflow cancelled. All files and approvals are kept.', next_action = wf_next(st))
}

wf_activate_model <- function(root, model_id, approved = FALSE) {
  st <- wf_read(root)
  wf_require_open(st)
  if (!isTRUE(approved)) refuse('Changing the active model requires the user\'s explicit approval: pass --approved true only after the user approved this model.')
  m <- st$models[[model_id]]
  if (is.null(m)) fail('Unknown model id "', model_id, '". Registered: ', paste(names(st$models), collapse = ', '))
  wf_require(!identical(model_id, st$active_model_id), sprintf('Model %s is already active.', model_id))
  wf_verify_model(st, m)
  old <- st$models[[st$active_model_id]]; old$status <- 'inactive'; st <- wf_store_model(st, old)
  m$status <- 'active'; m$activated_utc <- wf_now(); m$activated_by <- 'user approval (--approved true)'; st <- wf_store_model(st, m)
  st$active_model_id <- model_id; if (identical(st$status, 'complete')) st$status <- 'active'
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = sprintf('active model changed from %s to %s', old$model_id, model_id),
                                                   G = m$G, loglik = m$loglik, BIC = m$BIC, AIC = m$AIC, settings = m$settings)
  st <- wf_log(st, 'activate-model', model_id); wf_write(st)
  list(status = 'ACTIVE', message = sprintf('Active model is now %s (G = %s, log-lik %.4f, BIC %.3f). Earlier model %s and its outputs are kept.', model_id, m$G, m$loglik, m$BIC, old$model_id), next_action = wf_next(st))
}

wf_models <- function(root) {
  st <- wf_read(root)
  if (is.null(st$models)) return(list(status = 'NONE', message = 'No models are registered yet.', next_action = wf_next(st)))
  rows <- vapply(st$models, function(m) sprintf('%s [%s] origin=%s G=%s loglik=%.4f BIC=%.3f AIC=%.3f tol=%s starts=%s seed=%s stage5=%s stage6=%s dir=%s', m$model_id, m$status, m$origin, m$G, m$loglik, m$BIC, m$AIC,
                                               m$settings$tol, m$settings$n_starts, m$settings$seed, if (is.null(m$stage5)) 'no' else 'yes', if (is.null(m$stage6)) 'no' else 'yes', m$dir), character(1))
  list(status = 'OK', message = paste(c('', rows), collapse = '\n'), next_action = wf_next(st))
}

wf_report <- function(root, title = NULL, lang = 'en') {
  if (!identical(length(lang), 1L) || !lang %in% RP_LANGS) fail('--lang must be one of: ', paste(RP_LANGS, collapse = ', '), '.')
  st <- wf_read(root)
  wf_require(!is.null(st$stages$stage2), 'A report needs at least the Stage 2 diagnostics.')
  m <- NULL
  if (!is.null(st$active_model_id)) {
    m <- wf_use_active(st); others <- st$models[setdiff(names(st$models), m$model_id)]
    has <- function(k) any(vapply(others, function(o) !is.null(o[[k]]), logical(1)))
    if (is.null(m$stage5) && has('stage5')) fail(sprintf('Active model %s has no Stage 5 results (another model does). Run stage5 for it first; outputs of different models are never mixed.', m$model_id))
    if (!is.null(m$stage5) && is.null(m$stage6) && has('stage6')) fail(sprintf('Active model %s has no Stage 6 results (another model does). Run stage6 for it first; outputs of different models are never mixed.', m$model_id))
  }
  out <- wf_new_dir(st$root, 'report')
  r <- final_report(wf_manifest(st, title), out, lang = lang)
  st$stages$report <- c(st$stages$report, out); if (identical(st$status, 'active') && !is.null(m$stage6)) st$status <- 'complete'
  st$stages$report_lang <- c(unlist(st$stages$report_lang), lang) # rc4: report language only; analysis records are unchanged
  st <- wf_log(st, 'report', out); wf_write(st)
  list(status = 'DONE', message = sprintf('Report with %d sections and %d figures.', length(r$sections), r$n_figures), next_action = wf_next(st), output = out)
}

wf_status <- function(root) {
  st <- wf_read(root)
  done <- names(st$stages)[!vapply(st$stages, is.null, logical(1))]
  tmp <- wf_interrupted_writes(st$root)
  list(status = st$status, message = paste0(sprintf('Stages recorded: %s; approvals: %d; active model: %s.', paste(done, collapse = ', '), length(st$approvals), if (is.null(st$active_model_id)) 'none' else st$active_model_id),
                                            if (!is.null(st$gate)) sprintf(' Last gate: %s (%s, %s).', st$gate$outcome, st$gate$stage, st$gate$code) else ' Last gate: not recorded (older workflow).',
                                            if (length(tmp)) sprintf(' WARNING: %d interrupted state write(s) found; the state file is the last complete version.', length(tmp)) else ''), next_action = wf_next(st))
}

# ---------------------------------------------------------------- CLI
wf_cli <- function(argv) {
  if (!length(argv)) fail('Usage: workflow.R <command> --root <dir> [--key value ...]')
  cmd <- argv[1]; rest <- argv[-1]
  if (length(rest) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list(); for (i in seq(1L, length(rest), by = 2L)) { if (!startsWith(rest[i], '--')) fail('Expected --key, received: ', rest[i]); a[[substring(rest[i], 3L)]] <- rest[i + 1L] }
  if (!cmd %in% c('new-run', 'runs') && is.null(a$root)) fail('--root is required.')
  tf <- function(v) identical(v, 'true')
  allowed <- list(`new-run` = c('analysis', 'import-record', 'columns', 'objective', 'objective-text', 'label', 'data-source', 'results-dir', 'approval-ref', 'approved'), runs = c('analysis', 'results-dir'),
                  init = c('root', 'input', 'columns', 'objective', 'objective-text', 'label', 'data-source'), stage2 = 'root',
                  `stage2-handle` = c('root', 'method', 'k', 'all-missing-action', 'approved'),
                  stage3 = c('root', 'g', 'scale', 'rows-independent', 'independence-note', 'approved'),
                  stage4 = c('root', 'n-starts', 'seed', 'tol', 'max-iter', 'init'), stage5 = c('root', 'ambiguity-threshold'),
                  `register-model` = c('root', 'stage4-dir'), `activate-model` = c('root', 'model-id', 'approved'), models = 'root', cancel = c('root', 'reason', 'approved'),
                  stage6 = c('root', 'compare-g', 'strata', 'strata-columns'), `stage6-replay` = c('root', 'g', 'approved'), report = c('root', 'title', 'lang'), status = 'root',
                  `sensitivity-status` = 'root', `confirm-convergence` = c('root', 'model-id', 'approved'), `sensitivity-plan` = c('root', 'n-starts', 'tol', 'max-iter', 'seed', 'g', 'init'),
                  `sensitivity-run` = c('root', 'plan', 'approval-ref', 'approved'), `sensitivity-close` = c('root', 'plan', 'decision', 'approval-ref', 'approved'))
  if (!cmd %in% names(allowed)) fail('Unknown command "', cmd, '". Commands: ', paste(names(allowed), collapse = ', '))
  bad <- setdiff(names(a), allowed[[cmd]]); if (length(bad)) fail('Unknown option(s) for ', cmd, ': --', paste(bad, collapse = ', --'))
  ri <- a[['rows-independent']]; if (!is.null(ri)) ri <- switch(ri, true = TRUE, false = FALSE, assumed = 'assumed', fail('--rows-independent must be true, false or assumed.'))
  num <- function(v, d) if (is.null(v)) d else as.numeric(v)
  rd <- if (is.null(a[['results-dir']])) 'results' else a[['results-dir']]
  r <- switch(cmd,
    cancel = wf_cancel(a$root, a$reason, approved = tf(a$approved)),
    `new-run` = wf_new_run(a$analysis, a[['import-record']], a$columns, a$objective, a[['objective-text']], a$label, a[['data-source']], rd, approved = tf(a$approved), approval_ref = a[['approval-ref']]),
    runs = wf_runs(a$analysis, rd),
    init = wf_init(a$root, a$input, a$columns, a$objective, a[['objective-text']], a$label, a[['data-source']]),
    stage2 = wf_stage2(a$root),
    `stage2-handle` = wf_stage2_handle(a$root, a$method, k = as.integer(num(a$k, 5)), all_missing_action = a[['all-missing-action']], approved = tf(a$approved)),
    stage3 = wf_stage3(a$root, g = if (is.null(a$g)) '1:5' else a$g, scale = a$scale, rows_independent = ri, independence_note = a[['independence-note']], approved = tf(a$approved)),
    stage4 = wf_stage4(a$root, n_starts = as.integer(num(a[['n-starts']], EM_DEFAULTS$n_starts)), seed = as.integer(num(a$seed, EM_DEFAULTS$seed)),
                       tol = num(a$tol, EM_DEFAULTS$tol), max_iter = as.integer(num(a[['max-iter']], EM_DEFAULTS$max_iter)), init = if (is.null(a$init)) EM_DEFAULTS$init else a$init),
    stage5 = wf_stage5(a$root, ambiguity_threshold = num(a[['ambiguity-threshold']], 0.10)),
    `register-model` = wf_register_model(a$root, a[['stage4-dir']]),
    `activate-model` = wf_activate_model(a$root, a[['model-id']], approved = tf(a$approved)),
    models = wf_models(a$root),
    stage6 = wf_stage6(a$root, compare_g = a[['compare-g']], strata = a$strata, strata_columns = a[['strata-columns']]),
    `stage6-replay` = wf_stage6_replay(a$root, a$g, approved = tf(a$approved)),
    report = wf_report(a$root, a$title, if (is.null(a$lang)) 'en' else a$lang), status = wf_status(a$root),
    `sensitivity-status` = sens_status(a$root),
    `confirm-convergence` = sens_confirm_convergence(a$root, a[['model-id']], approved = tf(a$approved)),
    `sensitivity-plan` = sens_plan(a$root, n_starts = a[['n-starts']], tol = a$tol, max_iter = a[['max-iter']], seed = a$seed, g = a$g, init = a$init),
    `sensitivity-run` = sens_run(a$root, a$plan, a[['approval-ref']], approved = tf(a$approved)),
    `sensitivity-close` = sens_close(a$root, a$plan, a$decision, a[['approval-ref']], approved = tf(a$approved)))
  r$command <- cmd
  if (cmd %in% c('stage2', 'stage2-handle', 'stage3', 'stage4', 'cancel', 'sensitivity-plan', 'sensitivity-run', 'sensitivity-close')) r$gate <- wf_read(a$root)$gate
  r
}

if (sys.nframe() == 0L) {
  wf_argv <- commandArgs(trailingOnly = TRUE); wf_stage_name <- if (length(wf_argv)) wf_argv[1] else 'workflow'
  r <- tryCatch(wf_cli(wf_argv), stage2_pause = function(e) { cat(conditionMessage(e), '\n'); gmm_finish('AWAITING_USER_APPROVAL', wf_stage_name, e$code, 'See the options above.') },
                error = function(e) gmm_cli_error(e, wf_stage_name))
  cat('Status:', r$status, '\n'); if (!is.null(r$message)) cat(r$message, '\n')
  if (length(r$outstanding)) cat('Outstanding:\n', paste0('  - ', r$outstanding, '\n'), sep = '')
  if (!is.null(r$output)) cat('Output:', r$output, '\n')
  cat('Next:', r$next_action, '\n')
  if (!is.null(r$gate)) gmm_finish(r$gate$outcome, r$gate$stage, r$gate$code, r$next_action) else gmm_finish('SUCCESS', r$command, as.character(r$status), r$next_action)
}
