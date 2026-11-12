#!/usr/bin/env Rscript
# Stage 2 data profiling and explicitly approved missing-data handling.
# Runtime dependency: jsonlite (plus base R: utils, stats, graphics, grDevices, tools).
# No GMM fitting in this module.
#
# Execution phases:
#   1. Checks: arguments, paths, input, approval, Inf, KNN feasibility. Nothing is written.
#   2. In-memory processing (complete-case / mean / median / KNN). Nothing is written.
#   3. Write every output to a staging directory beside the output path, validate it,
#      then rename it to the output path. On any failure the staging directory is removed
#      and existing files are left untouched.
suppressPackageStartupMessages(library(jsonlite))

STAGE2_VERSION <- '0.6.0'
STAGE2_METHODS <- c('diagnostics', 'complete-case', 'mean', 'median', 'knn')
STAGE2_CONFIG_KEYS <- c('input', 'columns', 'output', 'method', 'k', 'all-missing-action', 'label', 'eda')
STAGE2_CLI_KEYS <- c(STAGE2_CONFIG_KEYS, 'approved', 'config')

# ---- location of this script / Skill root (used to keep outputs out of the Skill) ----
stage2_script_path <- function() {
  for (f in rev(sys.frames())) {
    of <- f$ofile
    if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/'))
  }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
STAGE2_SKILL_ROOT <- local({
  p <- stage2_script_path()
  if (is.na(p)) NA_character_ else dirname(dirname(p))
})
if (is.na(STAGE2_SKILL_ROOT)) stop('Cannot locate the multivariate-gmm Skill directory.', call. = FALSE)
source(file.path(STAGE2_SKILL_ROOT, 'scripts', 'eda_stage2.R'), local = TRUE)

# ---- conditions ----
fail <- function(...) stop(paste0(...), call. = FALSE)
# A PAUSE is not a bug: the user must choose how to continue. Nothing has been written.
pause <- function(code, message, details = list()) {
  stop(structure(class = c('stage2_pause', 'error', 'condition'),
                 list(message = message, call = NULL, code = code, details = details)))
}

# Outcome contract shared by the CLIs. BLOCKED is a statistical or data judgement; ERROR is a failed execution; REFUSED means nothing ran.
GMM_EXIT <- c(SUCCESS = 0L, ERROR = 1L, AWAITING_USER_APPROVAL = 2L, BLOCKED = 3L, REFUSED = 4L)
refuse <- function(...) stop(structure(class = c('gmm_refused', 'error', 'condition'), list(message = paste0(...), call = NULL)))
gmm_finish <- function(outcome, stage, code, next_action) {
  cat(sprintf('Outcome: %s\nExit-Code: %d\nStage: %s\nCode: %s\nNext-Action: %s\n', outcome, GMM_EXIT[[outcome]], stage, code, gsub('[\r\n]+', ' ', next_action)))
  if (outcome != 'SUCCESS') quit(save = 'no', status = GMM_EXIT[[outcome]])
  invisible(TRUE)
}
gmm_cli_error <- function(e, stage) {
  r <- inherits(e, 'gmm_refused')
  cat(if (r) 'Refused:' else 'Error:', conditionMessage(e), '\n', file = stderr())
  gmm_finish(if (r) 'REFUSED' else 'ERROR', stage, if (r) 'PRECONDITION_NOT_MET' else 'EXECUTION_ERROR', if (r) 'Satisfy the stated precondition, then rerun.' else 'Correct the problem shown in the error, then rerun.')
}

# ---- paths (relative paths resolve against the current working directory = project root) ----
is_absolute_path <- function(p) grepl('^(~|[A-Za-z]:[/\\\\]|[/\\\\])', p)
resolve_path <- function(p) {
  p <- path.expand(p)
  if (!is_absolute_path(p)) p <- file.path(getwd(), p)
  p <- gsub('\\\\', '/', p)
  parts <- strsplit(p, '/', fixed = TRUE)[[1L]]
  out <- character()
  for (s in parts) {
    if (s == '' && length(out)) next
    if (s == '.') next
    if (s == '..') { if (length(out) > 1L) out <- out[-length(out)]; next }
    out <- c(out, s)
  }
  paste(out, collapse = '/')
}
path_key <- function(p) {
  p <- paste0(sub('/+$', '', resolve_path(p)), '/')
  if (.Platform$OS.type == 'windows') tolower(p) else p
}
path_within <- function(child, parent) {
  if (is.na(parent)) return(FALSE)
  startsWith(path_key(child), path_key(parent))
}

write_json_file <- function(x, file) {
  jsonlite::write_json(x, file, auto_unbox = TRUE, pretty = TRUE, na = 'null', null = 'null', digits = NA)
}
ids <- function(v) I(as.integer(v)) # keep JSON arrays even for length 0/1

# ---- KNN donor audit: records what knn_impute already computed; it never feeds back into the imputation ----
KNN_AUDIT_FILES <- c('knn_audit_cells.csv', 'knn_audit_donors.csv', 'knn_audit_standardization.csv', 'knn_audit_summary.json')
knn_audit_capture <- function(n, keep, xs, i, j, k, m, donors, available, can_use, means, sds, target, dist, neighbors, value) {
  id <- sprintf('C%05d', n); vn <- names(xs)[j]; src <- keep[i]; dist <- unname(dist)
  pos <- match(neighbors, can_use); d <- dist[pos]; used <- length(neighbors)
  left <- setdiff(seq_along(can_use), pos)
  tied_out <- if (length(left)) keep[can_use[left][dist[left] == d[used]]] else integer()
  raw_sd <- vapply(xs[can_use, available, drop = FALSE], sd, numeric(1))
  other <- setdiff(which(m[i, ]), j)
  list(cell = data.frame(cell_id = id, source_row_id = src, variable = vn, k_requested = k, k_used = used, status = if (used < k) 'FEWER_THAN_K' else 'FULL_K',
                         predictors_used = paste(names(xs)[available], collapse = '|'), other_missing_in_row = paste(names(xs)[other], collapse = '|'),
                         n_candidate_donors = length(can_use), n_donors_excluded_missing_predictor = length(donors) - length(can_use),
                         n_distinct_donor_profiles = nrow(unique(xs[neighbors, available, drop = FALSE])), tie_at_k_boundary = length(tied_out) > 0L,
                         tied_excluded_source_rows = paste(tied_out, collapse = '|'), imputed_value = value, stringsAsFactors = FALSE, check.names = FALSE),
       donors = data.frame(cell_id = id, source_row_id = src, variable = vn, rank = seq_len(used), donor_source_row_id = keep[neighbors], distance = sqrt(d), distance_squared = d,
                           donor_value = xs[[j]][neighbors], tied_with_previous = c(FALSE, d[-1L] == d[-used]), stringsAsFactors = FALSE, check.names = FALSE),
       std = data.frame(cell_id = id, predictor = names(xs)[available], center = unname(means), scale = unname(sds), scale_rule = ifelse(!is.finite(raw_sd) | raw_sd == 0, 'set_to_1', 'sd'),
                        target_value = as.numeric(xs[i, available, drop = TRUE]), target_z = unname(target), stringsAsFactors = FALSE, check.names = FALSE, row.names = NULL))
}
knn_audit_bind <- function(items) {
  empty <- list(cell = data.frame(cell_id = character(), source_row_id = integer(), variable = character(), k_requested = integer(), k_used = integer(), status = character(), predictors_used = character(), other_missing_in_row = character(),
                                  n_candidate_donors = integer(), n_donors_excluded_missing_predictor = integer(), n_distinct_donor_profiles = integer(), tie_at_k_boundary = logical(), tied_excluded_source_rows = character(), imputed_value = numeric(), stringsAsFactors = FALSE),
                donors = data.frame(cell_id = character(), source_row_id = integer(), variable = character(), rank = integer(), donor_source_row_id = integer(), distance = numeric(), distance_squared = numeric(), donor_value = numeric(), tied_with_previous = logical(), stringsAsFactors = FALSE),
                std = data.frame(cell_id = character(), predictor = character(), center = numeric(), scale = numeric(), scale_rule = character(), target_value = numeric(), target_z = numeric(), stringsAsFactors = FALSE))
  if (!length(items)) return(list(cells = empty$cell, donors = empty$donors, standardization = empty$std))
  bind <- function(k) { r <- do.call(rbind, lapply(items, `[[`, k)); rownames(r) <- NULL; r }
  list(cells = bind('cell'), donors = bind('donors'), standardization = bind('std'))
}
# Internal consistency of an audit, on the values in memory or as read back from its files.
knn_audit_check <- function(a) {
  for (id in a$cells$cell_id) {
    cl <- a$cells[a$cells$cell_id == id, ]; d <- a$donors[a$donors$cell_id == id, ]
    if (nrow(d) != cl$k_used || !identical(as.integer(d$rank), seq_len(nrow(d)))) fail('KNN audit check failed for ', id, ': donor count or ranks.')
    if (mean(d$donor_value) != cl$imputed_value) fail('KNN audit check failed for ', id, ': the donor mean does not equal the imputed value.')
    if (any(d$distance != sqrt(d$distance_squared))) fail('KNN audit check failed for ', id, ': distance and distance_squared disagree.')
    if (is.unsorted(order(d$distance_squared, d$donor_source_row_id))) fail('KNN audit check failed for ', id, ': donors are not in distance, then row, order.')
  }
  invisible(TRUE)
}
knn_audit_csv <- function(df, file, numeric_cols, text_cols) {
  for (v in numeric_cols) df[[v]] <- sprintf('%.17g', df[[v]])
  write.csv(df, file, row.names = FALSE, quote = which(names(df) %in% text_cols), na = '')
}
knn_audit_write <- function(a, dir, meta) {
  knn_audit_check(a)
  knn_audit_csv(a$cells, file.path(dir, 'knn_audit_cells.csv'), 'imputed_value', c('cell_id', 'variable', 'status', 'predictors_used', 'other_missing_in_row', 'tied_excluded_source_rows'))
  knn_audit_csv(a$donors, file.path(dir, 'knn_audit_donors.csv'), c('distance', 'distance_squared', 'donor_value'), c('cell_id', 'variable'))
  knn_audit_csv(a$standardization, file.path(dir, 'knn_audit_standardization.csv'), c('center', 'scale', 'target_value', 'target_z'), c('cell_id', 'predictor', 'scale_rule'))
  back <- list(cells = read.csv(file.path(dir, 'knn_audit_cells.csv'), check.names = FALSE, stringsAsFactors = FALSE), donors = read.csv(file.path(dir, 'knn_audit_donors.csv'), check.names = FALSE, stringsAsFactors = FALSE))
  if (nrow(back$cells)) knn_audit_check(back)
  write_json_file(c(list(audit_version = '0.1.0', algorithm = c('For each missing cell: predictors are the other variables observed in that row; the missing variable itself is never used.',
                                                                 'Candidate donors observe the target variable and every predictor of that row.',
                                                                 'Each predictor is standardized with the mean and SD of the candidate donors; an SD that is zero or undefined is set to 1.',
                                                                 'distance_squared is the sum of squared standardized differences; distance is its square root.',
                                                                 'The k nearest candidates are used, or all of them when there are fewer; ties are resolved by the smaller row position.',
                                                                 'The imputed value is the unweighted mean of the donors\' observed values; imputed values never act as donors.'),
                      n_cells = nrow(a$cells), n_donor_rows = nrow(a$donors), n_cells_fewer_than_k = sum(a$cells$status == 'FEWER_THAN_K'), n_cells_tie_at_k_boundary = sum(a$cells$tie_at_k_boundary),
                      n_cells_with_other_missing_predictors = sum(nzchar(a$cells$other_missing_in_row)), n_cells_scale_set_to_1 = length(unique(a$standardization$cell_id[a$standardization$scale_rule == 'set_to_1'])),
                      notes = 'n_distinct_donor_profiles is descriptive; it is not an effective sample size.', checks = 'donor mean equals imputed value; distance equals the square root of distance_squared; donors in distance then row order: passed'), meta),
                  file.path(dir, 'knn_audit_summary.json'))
  invisible(TRUE)
}

# ---- KNN (in memory; returns failures instead of stopping so they can all be reported) ----
knn_impute <- function(x, keep, k) {
  xs <- x[keep, , drop = FALSE]
  p <- ncol(xs)
  out <- xs
  m <- is.na(xs)
  failures <- data.frame(source_row_id = integer(), variable = character(), reason = character(),
                         stringsAsFactors = FALSE)
  fewer_than_k <- 0L
  audit <- list()
  for (j in seq_len(p)) {
    need <- which(m[, j])
    if (!length(need)) next
    donors <- which(!m[, j])
    for (i in need) {
      available <- setdiff(which(!m[i, ]), j)
      if (!length(available)) {
        failures[nrow(failures) + 1L, ] <- list(keep[i], names(xs)[j], 'no observed predictor variables')
        next
      }
      can_use <- donors[rowSums(m[donors, available, drop = FALSE]) == 0L]
      if (!length(can_use)) {
        failures[nrow(failures) + 1L, ] <- list(keep[i], names(xs)[j],
          paste0('no donor row observes ', names(xs)[j], ' together with ',
                 paste(names(xs)[available], collapse = '+')))
        next
      }
      means <- vapply(xs[can_use, available, drop = FALSE], mean, numeric(1))
      sds <- vapply(xs[can_use, available, drop = FALSE], sd, numeric(1))
      sds[!is.finite(sds) | sds == 0] <- 1
      z <- sweep(sweep(as.matrix(xs[can_use, available, drop = FALSE]), 2, means, '-'), 2, sds, '/')
      target <- (as.numeric(xs[i, available, drop = TRUE]) - means) / sds
      dist <- rowSums(sweep(z, 2, target, '-')^2)
      if (length(can_use) < k) fewer_than_k <- fewer_than_k + 1L
      neighbors <- can_use[order(dist, can_use)[seq_len(min(k, length(can_use)))]]
      out[[j]][i] <- mean(xs[[j]][neighbors])
      audit[[length(audit) + 1L]] <- knn_audit_capture(length(audit) + 1L, keep, xs, i, j, k, m, donors, available, can_use, means, sds, target, dist, neighbors, out[[j]][i])
    }
  }
  list(processed = out, failures = failures, cells_fewer_than_k_donors = fewer_than_k, audit = knn_audit_bind(audit))
}

format_cells <- function(f, limit = 20L) {
  s <- sprintf('row %d %s (%s)', f$source_row_id, f$variable, f$reason)
  if (length(s) > limit) s <- c(s[seq_len(limit)], sprintf('... and %d more', length(s) - limit))
  paste(s, collapse = '; ')
}

# ---- staged write + commit ----
stage_and_commit <- function(output_path, writer, validator) {
  parent <- dirname(output_path)
  created <- character()
  d <- parent
  while (!dir.exists(d)) { created <- c(created, d); d <- dirname(d) }
  if (length(created) && !dir.create(parent, recursive = TRUE, showWarnings = FALSE)) {
    fail('Could not create parent directory: ', parent)
  }
  stamp <- gsub('[^0-9]', '', format(Sys.time(), '%Y%m%d%H%M%OS6'))
  stage <- file.path(parent, sprintf('.%s.staging-%d-%s', basename(output_path), Sys.getpid(), stamp))
  if (!dir.create(stage, showWarnings = FALSE)) fail('Could not create staging directory: ', stage)
  committed <- FALSE
  on.exit({
    if (!committed) {
      unlink(stage, recursive = TRUE, force = TRUE)
      for (cd in created) { # deepest first; only remove what this run created and left empty
        if (dir.exists(cd) && !length(list.files(cd, all.files = TRUE, no.. = TRUE))) unlink(cd, recursive = TRUE)
      }
    }
  }, add = TRUE)
  writer(stage)
  validator(stage)
  if (isTRUE(getOption('gmm.stage2.fail_before_commit', FALSE))) fail('Simulated failure before commit (test hook).')
  if (dir.exists(output_path)) {
    if (length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
      fail('Output directory gained files during processing; existing results were not overwritten.')
    }
    unlink(output_path, recursive = TRUE)
  }
  if (!file.rename(stage, output_path)) fail('Could not move staged results into: ', output_path)
  committed <- TRUE
  invisible(output_path)
}

# ---- main entry ----
analyze <- function(input, columns, output, method = 'diagnostics', approved = FALSE, k = 5L,
                    all_missing_action = NULL, label = NULL, eda = TRUE, config_file = NULL) {
  # ===== Phase 1: checks (nothing is written) =====
  if (!is.character(method) || length(method) != 1L || !method %in% STAGE2_METHODS) {
    fail('Unsupported method: ', paste(method, collapse = ','), '. Allowed: ', paste(STAGE2_METHODS, collapse = ', '))
  }
  approved <- isTRUE(approved)
  if (!is.logical(eda) || length(eda) != 1L || is.na(eda)) fail('eda must be TRUE or FALSE.')
  if (!is.null(label) && (!is.character(label) || length(label) != 1L || !nzchar(label))) fail('label must be one column name.')
  if (!is.null(all_missing_action)) {
    if (!identical(all_missing_action, 'drop')) fail("--all-missing-action only accepts 'drop'.")
    if (method != 'knn') fail('--all-missing-action applies only to --method knn.')
  }
  if (method == 'knn') {
    if (length(k) != 1L || !is.numeric(k) || is.na(k) || k < 1 || k != round(k)) fail('k must be a positive integer.')
    k <- as.integer(k)
  }
  input_path <- resolve_path(input)
  if (!file.exists(input_path) || dir.exists(input_path)) fail('Input CSV not found: ', input_path)
  output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) {
    fail('Output path is inside the Skill directory (', STAGE2_SKILL_ROOT, '). ',
         'Write results under the project working directory, e.g. results/<name>.')
  }
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  if (path_within(input_path, output_path)) fail('Input file must not be inside the output directory.')

  raw <- read.csv(input_path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''),
                  fileEncoding = 'UTF-8-BOM')
  if (nrow(raw) < 1L) fail('Input contains zero rows.')
  cols <- trimws(strsplit(columns, ',', fixed = TRUE)[[1L]])
  if (length(cols) < 2L || anyDuplicated(cols) || any(!cols %in% names(raw))) fail('Provide at least two distinct, existing columns.')
  if (!is.null(label)) {
    if (!label %in% names(raw)) fail('Label column not found: ', label)
    if (label %in% cols) fail('Label column must not be one of the analysis --columns (it is reserved for external validation).')
  }
  x <- raw[, cols, drop = FALSE]
  if (!all(vapply(x, is.numeric, logical(1)))) fail('Selected columns must be numeric; encoded categorical columns require review.')
  n <- nrow(x); p <- ncol(x)
  missing <- matrix(as.matrix(is.na(x)), nrow = n, ncol = p) # NA and NaN
  nan <- matrix(vapply(x, is.nan, logical(n)), nrow = n, ncol = p)
  inf <- matrix(vapply(x, is.infinite, logical(n)), nrow = n, ncol = p)
  inf_n <- sum(inf); nan_n <- sum(nan); missing_n <- sum(missing); na_n <- sum(missing & !nan)
  complete <- rowSums(missing) == 0L & rowSums(inf) == 0L
  all_missing <- which(rowSums(missing) == p)

  if (method != 'diagnostics') {
    if (!approved) refuse('Processing requires explicit user approval: --approved true')
    if (inf_n > 0L) fail('Inf or -Inf must be reviewed/corrected; not treated as ordinary missingness.')
  }

  # ===== Phase 2: in-memory processing (nothing is written) =====
  processed <- NULL; row_index <- seq_len(n); removed <- integer(); fewer_k <- NA_integer_; knn_audit <- NULL
  if (method == 'complete-case') {
    if (!any(complete)) fail('Complete-case analysis would retain zero rows.')
    row_index <- which(complete); removed <- which(!complete)
    processed <- x[complete, , drop = FALSE]
  } else if (method %in% c('mean', 'median')) {
    processed <- x
    for (j in seq_len(p)) {
      need <- which(missing[, j])
      if (!length(need)) next
      if (all(missing[, j])) fail('No observed values in column: ', cols[j])
      obs <- x[[j]][!missing[, j]]
      processed[[j]][need] <- if (method == 'mean') mean(obs) else median(obs)
    }
  } else if (method == 'knn') {
    if (length(all_missing) && is.null(all_missing_action)) {
      pause('KNN_ALL_MISSING_ROWS', paste0(
        'PAUSE [KNN_ALL_MISSING_ROWS]: ', length(all_missing), ' observation(s) have every selected variable missing ',
        '(source rows: ', paste(all_missing, collapse = ', '), '). KNN has no predictor for them.\n',
        'KNN was not run and no files were written. Ask the user to choose:\n',
        '  A. Drop these rows and continue KNN on the remaining rows: rerun with --all-missing-action drop --approved true\n',
        '  B. Cancel KNN and return to the missing-data handling menu (complete-case / mean / median / KNN / diagnostics)\n',
        '  C. Output missing-data diagnostics only: rerun with --method diagnostics'),
        list(source_rows = all_missing))
    }
    removed <- all_missing
    row_index <- setdiff(seq_len(n), removed)
    if (!length(row_index)) fail('No rows remain after dropping all-missing rows.')
    res <- knn_impute(x, row_index, k)
    if (nrow(res$failures)) {
      pause('KNN_NO_VALID_NEIGHBORS', paste0(
        'PAUSE [KNN_NO_VALID_NEIGHBORS]: KNN cannot compute a valid distance for ', nrow(res$failures),
        ' missing cell(s): ', format_cells(res$failures), '.\n',
        'KNN was not run and no files were written. Ask the user to choose:\n',
        '  A. Return to the missing-data handling menu and pick complete-case, mean or median\n',
        '  B. Revise the selected variables (--columns) and rerun diagnostics\n',
        '  C. Output missing-data diagnostics only: rerun with --method diagnostics'),
        list(cells = res$failures))
    }
    processed <- res$processed
    fewer_k <- res$cells_fewer_than_k_donors
    knn_audit <- res$audit
  }
  if (!is.null(processed) && (!nrow(processed) || any(!is.finite(as.matrix(processed))))) {
    fail('Processing failed to yield a nonempty finite dataset.')
  }
  imputed_by_var <- if (method %in% c('mean', 'median', 'knn')) {
    as.list(setNames(as.integer(colSums(missing[row_index, , drop = FALSE])), cols))
  } else as.list(setNames(rep(0L, p), cols))
  imputed_total <- sum(unlist(imputed_by_var))

  # ----- EDA plan, external label bookkeeping, effective configuration -----
  eda_status <- if (!eda) 'disabled (--eda false)' else if (inf_n > 0L) 'skipped: Inf values present; correct them first' else 'completed'
  run_eda <- identical(eda_status, 'completed')
  label_counts <- NULL; label_out <- NULL
  if (!is.null(label)) {
    lv <- ifelse(is.na(raw[[label]]), '<NA>', as.character(raw[[label]]))
    lev <- sort(unique(lv))
    any_missing <- rowSums(missing) > 0L
    label_counts <- data.frame(level = lev,
      n_input = vapply(lev, function(l) sum(lv == l), integer(1)),
      rows_with_any_missing_feature = vapply(lev, function(l) sum(lv == l & any_missing), integer(1)),
      n_retained = vapply(lev, function(l) sum(lv[row_index] == l), integer(1)), row.names = NULL)
    if (!is.null(processed)) label_out <- setNames(data.frame(row_index, raw[[label]][row_index]), c('source_row_id', label))
  }
  run_config <- list(script_version = STAGE2_VERSION, input = input_path, columns = I(cols), label = label,
    output = output_path, method = method, k = if (method == 'knn') k else NULL,
    all_missing_action = all_missing_action, eda = eda, approved = approved,
    config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL)
  eda_results <- list()

  # ----- result objects -----
  rates <- data.frame(variable = cols, missing_count = colSums(missing), missing_rate = colMeans(missing),
                      nan_count = colSums(nan), inf_count = colSums(inf))
  mask <- apply(missing, 1L, function(v) paste(ifelse(v, 'M', 'O'), collapse = ''))
  patterns <- as.data.frame(table(mask), stringsAsFactors = FALSE)
  names(patterns) <- c('pattern', 'count')
  patterns <- patterns[order(-patterns$count, patterns$pattern), , drop = FALSE]
  patterns$rate <- patterns$count / n

  summary_obj <- list(status = NA_character_, n_observations = n, n_variables = p, variables = cols,
     overall_missing_rate = missing_n / (n * p), missing_cells = missing_n,
     na_cells = na_n, nan_cells = nan_n, infinite_cells = inf_n,
     complete_cases = sum(complete), incomplete_cases = n - sum(complete),
     all_missing_row_count = length(all_missing), all_missing_source_rows = ids(all_missing),
     requested_method = method, data_modified = FALSE, gmm_fitted = FALSE, output_dir = output_path,
     external_label = if (is.null(label)) NULL else list(column = label, used_in_statistics = FALSE,
                                                         n_levels = nrow(label_counts)),
     eda = list(status = eda_status, input_dir = if (run_eda) 'eda' else NULL,
                processed_dir = if (run_eda && !is.null(processed)) 'eda_processed' else NULL))
  if (method == 'diagnostics') {
    summary_obj$status <- if (inf_n > 0L) 'DIAGNOSTICS_WITH_INVALID_VALUES' else 'DIAGNOSTICS_ONLY'
    summary_obj$next_action <- 'REPORT_ONLY'
  } else {
    summary_obj$status <- 'PROCESSED_AWAITING_GMM_APPROVAL'
    summary_obj$data_modified <- TRUE
    summary_obj$rows_retained <- length(row_index)
    summary_obj$rows_removed <- length(removed)
    summary_obj$processing_details <- list(method = method, k = if (method == 'knn') k else NULL,
      all_missing_action = if (method == 'knn' && length(all_missing)) all_missing_action else NULL,
      imputed_cells = imputed_total)
    summary_obj$next_action <- 'USER_APPROVAL_THEN_STAGE3'
  }
  log_obj <- list(log_type = 'stage2_preprocessing', script_version = STAGE2_VERSION,
    timestamp_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
    input = list(path = input_path, md5 = unname(tools::md5sum(input_path)), n_rows = n),
    variables = cols, method = method, approved = approved,
    knn = if (method == 'knn') list(k = k, cells_with_fewer_than_k_donors = fewer_k, audit = list(files = I(KNN_AUDIT_FILES), n_cells = nrow(knn_audit$cells), n_cells_tie_at_k_boundary = sum(knn_audit$cells$tie_at_k_boundary))) else NULL,
    all_missing_rows = list(count = length(all_missing), source_row_ids = ids(all_missing),
                            action = if (method == 'knn' && length(all_missing)) all_missing_action else
                                     if (length(all_missing)) paste0('handled by method: ', method) else NULL),
    rows_removed = list(count = length(removed), source_row_ids = ids(removed)),
    rows_retained = length(row_index),
    imputed_cells = list(total = imputed_total, by_variable = imputed_by_var),
    missing_summary = list(overall_missing_rate = missing_n / (n * p), missing_cells = missing_n,
                           by_variable_rate = as.list(setNames(colMeans(missing), cols)),
                           complete_cases = sum(complete), incomplete_cases = n - sum(complete)),
    external_label = label,
    data_modified = method != 'diagnostics', gmm_fitted = FALSE,
    output_dir = output_path, r_version = R.version.string)

  required <- c('summary.json', 'preprocessing_log.json', 'run_config.json', 'variable_missing.csv',
                'pattern_summary.csv', 'data_overview.txt', 'missingness_map.png', 'missing_rate.png')
  if (!is.null(processed)) required <- c(required, 'processed_data.csv')
  if (!is.null(knn_audit)) required <- c(required, KNN_AUDIT_FILES)
  if (!is.null(label)) required <- c(required, 'external_label_counts.csv', if (!is.null(processed)) 'external_labels.csv')
  if (run_eda) {
    required <- c(required, file.path('eda', stage2_eda_required_files(p)))
    if (!is.null(processed)) required <- c(required, file.path('eda_processed', stage2_eda_required_files(p)))
  }

  # ===== Phase 3: staged write, validation, commit =====
  writer <- function(dir) {
    write.csv(rates, file.path(dir, 'variable_missing.csv'), row.names = FALSE)
    write.csv(patterns, file.path(dir, 'pattern_summary.csv'), row.names = FALSE)
    overview <- c(paste('Selected variables:', paste(cols, collapse = ', ')), capture.output(print(summary(x))))
    if (!is.null(processed)) {
      overview <- c(overview, '', paste0('Processed data (method = ', method, ', rows = ', nrow(processed), '):'),
                    capture.output(print(summary(processed))))
    }
    writeLines(overview, file.path(dir, 'data_overview.txt'))
    png(file.path(dir, 'missingness_map.png'), width = 1100, height = 680)
    tryCatch({
      par(mar = c(8, 5, 4, 2))
      image(x = seq_len(p), y = seq_len(n), z = t(missing * 1), col = c('#DDE8F2', '#C65C48'), zlim = c(0, 1),
            xlab = 'Variable', ylab = 'Source row index', main = 'Missingness map (red = missing)', axes = FALSE)
      axis(1, at = seq_len(p), labels = cols, las = 2, cex.axis = .85)
      axis(2); box()
    }, finally = dev.off())
    png(file.path(dir, 'missing_rate.png'), width = 1000, height = 650)
    tryCatch({
      par(mar = c(9, 5, 4, 1))
      barplot(rates$missing_rate, names.arg = cols, las = 2, ylim = c(0, max(0.05, rates$missing_rate) * 1.2),
              col = '#527DA3', ylab = 'Missing proportion', main = 'Missingness by variable')
    }, finally = dev.off())
    if (!is.null(processed)) {
      write.csv(data.frame(source_row_id = row_index, processed, check.names = FALSE),
                file.path(dir, 'processed_data.csv'), row.names = FALSE, na = '')
    }
    if (!is.null(knn_audit)) knn_audit_write(knn_audit, dir, list(mode = 'analysis', k = k, stage2_script_version = STAGE2_VERSION, input = list(path = input_path, md5 = unname(tools::md5sum(input_path)))))
    if (!is.null(label_counts)) write.csv(label_counts, file.path(dir, 'external_label_counts.csv'), row.names = FALSE)
    if (!is.null(label_out)) write.csv(label_out, file.path(dir, 'external_labels.csv'), row.names = FALSE, na = '')
    s <- summary_obj
    if (run_eda) {
      dir.create(file.path(dir, 'eda'))
      e1 <- stage2_eda(x, file.path(dir, 'eda'), title = 'input data (no rows removed or imputed)')
      eda_results$input_collinearity_flags <<- e1$collinearity_flags
      if (!is.null(processed)) {
        dir.create(file.path(dir, 'eda_processed'))
        e2 <- stage2_eda(processed, file.path(dir, 'eda_processed'), title = paste('processed data, method =', method))
        eda_results$processed_collinearity_flags <<- e2$collinearity_flags
      }
      s$eda <- c(s$eda, eda_results)
    }
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    write_json_file(log_obj, file.path(dir, 'preprocessing_log.json'))
    write_json_file(s, file.path(dir, 'summary.json'))
  }
  validator <- function(dir) {
    f <- file.path(dir, required)
    bad <- required[!file.exists(f) | file.size(f) <= 0]
    if (length(bad)) fail('Staged output incomplete: ', paste(bad, collapse = ', '))
    s <- jsonlite::fromJSON(file.path(dir, 'summary.json'))
    if (!identical(s$status, summary_obj$status)) fail('Staged summary.json failed validation.')
    if (!is.null(processed)) {
      d <- read.csv(file.path(dir, 'processed_data.csv'), check.names = FALSE)
      ok <- nrow(d) == length(row_index) && identical(names(d), c('source_row_id', cols)) &&
        !anyDuplicated(d$source_row_id) && all(is.finite(as.matrix(d)))
      if (!ok) fail('Staged processed_data.csv failed validation.')
    }
  }
  stage_and_commit(output_path, writer, validator)
  if (run_eda) summary_obj$eda <- c(summary_obj$eda, eda_results)
  invisible(summary_obj)
}

# ---- CLI ----
parse_args <- function(args) {
  if (length(args) %% 2L != 0L) fail('Arguments must use --key value pairs.')
  out <- list()
  for (i in seq(1L, length(args), by = 2L)) {
    key <- args[i]
    if (!startsWith(key, '--')) fail('Expected --key, received: ', key)
    key <- substring(key, 3L)
    if (!key %in% STAGE2_CLI_KEYS) fail('Unknown argument --', key, '. Allowed: --', paste(STAGE2_CLI_KEYS, collapse = ', --'))
    out[[key]] <- args[i + 1L]
  }
  out
}

# A JSON config holds reusable settings (keys = CLI names without '--'; '_' also accepted).
# Approval is deliberately NOT a config key: it must be given per run on the command line.
read_stage2_config <- function(path) {
  path <- resolve_path(path)
  if (!file.exists(path)) fail('Config file not found: ', path)
  cfg <- tryCatch(jsonlite::fromJSON(path, simplifyVector = TRUE), error = function(e) fail('Config is not valid JSON: ', conditionMessage(e)))
  if (!is.list(cfg)) fail('Config must be a JSON object.')
  names(cfg) <- gsub('_', '-', names(cfg))
  if ('approved' %in% names(cfg)) fail('"approved" is not allowed in a config file; pass --approved true on the command line after the user approves.')
  bad <- setdiff(names(cfg), STAGE2_CONFIG_KEYS)
  if (length(bad)) fail('Unknown config key(s): ', paste(bad, collapse = ', '), '. Allowed: ', paste(STAGE2_CONFIG_KEYS, collapse = ', '))
  lapply(cfg, function(v) if (is.logical(v)) tolower(as.character(v)) else paste(as.character(v), collapse = ','))
}

stage2_cli <- function(argv) {
  args <- parse_args(argv)
  if (!is.null(args$config)) {
    cfg <- read_stage2_config(args$config)
    for (key in names(cfg)) if (is.null(args[[key]])) args[[key]] <- cfg[[key]] # CLI overrides config
  }
  missing_args <- setdiff(c('input', 'columns', 'output'), names(args))
  if (length(missing_args)) fail('Missing settings (CLI or config): ', paste(missing_args, collapse = ', '))
  if (!is.null(args$approved) && !args$approved %in% c('true', 'false')) fail('--approved must be true or false.')
  if (!is.null(args$eda) && !args$eda %in% c('true', 'false')) fail('--eda must be true or false.')
  if (!is.null(args$k) && !grepl('^[0-9]+$', args$k)) fail('k must be a positive integer.')
  analyze(args$input, args$columns, args$output,
          method = if (is.null(args$method)) 'diagnostics' else args$method,
          approved = identical(args$approved, 'true'),
          k = if (is.null(args$k)) 5L else as.integer(args$k),
          all_missing_action = args[['all-missing-action']],
          label = args$label,
          eda = !identical(args$eda, 'false'),
          config_file = args$config)
}

if (sys.nframe() == 0L) {
  result <- tryCatch(stage2_cli(commandArgs(trailingOnly = TRUE)), stage2_pause = function(e) {
    cat(conditionMessage(e), '\n')
    gmm_finish('AWAITING_USER_APPROVAL', 'stage2', e$code, 'Present the options above to the user and rerun with the chosen one.')
  }, error = function(e) gmm_cli_error(e, 'stage2'))
  cat('Stage 2 status:', result$status, '\n')
  cat('EDA:', result$eda$status, '\n')
  flags <- c(result$eda$input_collinearity_flags, result$eda$processed_collinearity_flags)
  if (length(flags)) cat('EDA collinearity flags:', paste(unique(flags), collapse = '; '), '\n')
  cat('Output directory:', result$output_dir, '\n')
  if (identical(result$status, 'DIAGNOSTICS_WITH_INVALID_VALUES')) gmm_finish('BLOCKED', 'stage2', 'INVALID_VALUES_INF', 'Inf/-Inf are invalid, not missing: correct or exclude them before any processing.')
  gmm_finish('SUCCESS', 'stage2', result$status, if (identical(result$status, 'DIAGNOSTICS_ONLY') && result$missing_cells > 0) 'Present the missing-data menu to the user.' else 'Present the results to the user and confirm before Stage 3.')
}
