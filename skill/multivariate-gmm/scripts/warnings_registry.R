#!/usr/bin/env Rscript
# Analysis Warnings & Limitations Registry.
# Three classes are kept apart:
#   AUTO_DIAGNOSTIC           computed from the stage outputs at report time; never stored by hand
#   USER_APPROVED_LIMITATION  from an approved spec, or a confirmed write-once record
#   ANALYST_NOTE              an interpretation, confirmed by the user; never an established statistical result
# Records live in one analysis-specific directory, one file each, and are append-only (correct one with --supersedes).
# A text the user has not yet seen word for word is written as a candidate (propose) and enters a report only after approve.
# Approved specs, models and stage outputs are read only; this module never edits them.
# Usage: Rscript warnings_registry.R annotate|propose|approve|list ...
suppressPackageStartupMessages(library(jsonlite))

wr_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
WR_SCRIPT_DIR <- dirname(wr_script_path())
if (!exists('resolve_path', inherits = TRUE)) source(file.path(WR_SCRIPT_DIR, 'data_stage2.R'), local = TRUE)
if (!exists('skill_sha256', inherits = TRUE)) source(file.path(WR_SCRIPT_DIR, 'hash_utils.R'), local = TRUE) # Cowork release: SHA-256 on R >= 4.1

WR_VERSION <- '0.1.0'
WR_CLASSES <- c('AUTO_DIAGNOSTIC', 'USER_APPROVED_LIMITATION', 'ANALYST_NOTE')
WR_SEVERITIES <- c('INFO', 'WARNING', 'LIMITATION')
WR_SCOPES <- c('data', 'spec', 'model')
WR_STAGES <- as.character(1:6)
WR_CANDIDATE_DIR <- 'candidates'

# ---------------------------------------------------------------- identity
wr_sha <- function(f) unname(skill_sha256(f)) # SHA-256 only; a missing file gives NA, which never matches a recorded hash
wr_model_id <- function(stage4_dir) {
  if (is.null(stage4_dir)) return(NULL)
  j <- file.path(stage4_dir, 'selected_model.json'); r <- file.path(stage4_dir, 'selected_model.rds')
  if (!file.exists(j) || !file.exists(r)) return(NULL)
  sprintf('G%d-%s', as.integer(jsonlite::fromJSON(j, simplifyVector = TRUE)$selected_G), substr(wr_sha(r), 1, 12))
}
wr_identity <- function(input_md5, spec = NULL, stage4_dir = NULL) {
  if (is.null(input_md5) || !nzchar(input_md5)) fail('The input file checksum is required to identify the analysis.')
  list(input_md5 = input_md5, analysis_data_md5 = spec$input$md5, spec_hash = spec$spec_hash, approval_id = spec$approval_id, model_id = wr_model_id(stage4_dir))
}
wr_identity_dirs <- function(stage2_dir, stage3_dir = NULL, stage4_dir = NULL) {
  f <- file.path(resolve_path(stage2_dir), 'preprocessing_log.json')
  if (!file.exists(f)) fail('Stage 2 directory has no preprocessing_log.json: ', stage2_dir)
  sp <- if (is.null(stage3_dir)) NULL else {
    g <- file.path(resolve_path(stage3_dir), 'stage3_spec.json'); if (!file.exists(g)) fail('Stage 3 directory has no stage3_spec.json: ', stage3_dir)
    s <- jsonlite::fromJSON(g, simplifyVector = TRUE); if (!isTRUE(s$approved_for_fit)) fail('The Stage 3 specification is not approved: ', g); s
  }
  d4 <- if (is.null(stage4_dir)) NULL else resolve_path(stage4_dir)
  id <- wr_identity(jsonlite::fromJSON(f, simplifyVector = TRUE)$input$md5, sp, d4)
  if (!is.null(d4) && is.null(id$model_id)) fail('Stage 4 directory has no selected model: ', d4)
  id
}

# ---------------------------------------------------------------- content hash (covers text, source, approval and evidence references)
wr_canon <- function(x) {
  if (!is.list(x)) return(x)
  if (!is.null(names(x))) x <- x[order(names(x))]
  lapply(x, wr_canon)
}
wr_content_hash <- function(rec) {
  rec$content_sha256 <- NULL
  txt <- as.character(jsonlite::toJSON(wr_canon(rec), auto_unbox = TRUE, digits = NA, null = 'null'))
  f <- tempfile(); on.exit(unlink(f)); writeBin(charToRaw(enc2utf8(txt)), f); wr_sha(f)
}

# ---------------------------------------------------------------- evidence references
# One of: JSON `path`; CSV `count_where` (rows matching); CSV `field` located by `where` (one row) or `row` (1-based row number).
wr_read_cell <- function(e) {
  if (!file.exists(e$file)) fail('Evidence file not found: ', e$file)
  if (!is.null(e$path)) {
    v <- jsonlite::fromJSON(e$file, simplifyVector = TRUE)
    for (k in unlist(e$path)) v <- v[[k]]
    if (is.null(v) || length(v) != 1L) fail('Evidence path not found in ', e$file, ': ', paste(unlist(e$path), collapse = '.'))
    return(v)
  }
  d <- read.csv(e$file, check.names = FALSE, stringsAsFactors = FALSE)
  match_rows <- function(w) { if (!all(names(w) %in% names(d))) fail('Evidence column not found in ', e$file, '.'); k <- rep(TRUE, nrow(d)); for (n in names(w)) k <- k & !is.na(d[[n]]) & as.character(d[[n]]) == as.character(w[[n]]); k }
  if (!is.null(e$count_where)) return(sum(match_rows(e$count_where)))
  if (is.null(e$field) || !e$field %in% names(d)) fail('Evidence column not found in ', e$file, '.')
  if (!is.null(e$row)) { if (e$row < 1 || e$row > nrow(d)) fail('Evidence row out of range in ', e$file, '.'); return(d[[e$field]][e$row]) }
  k <- match_rows(e$where)
  if (sum(k) != 1L) fail('Evidence locator must match exactly one row in ', e$file, ' (matched ', sum(k), ').')
  d[[e$field]][k]
}
wr_format_value <- function(v) if (length(v) == 1L && is.na(v)) 'missing' else if (is.numeric(v)) { if (v == round(v)) as.character(v) else formatC(v, format = 'f', digits = 4) } else as.character(v)
wr_check_expected <- function(e, v) {
  force(v) # the locator must be read even when no expected value is given
  if (is.null(e$expected)) return(invisible(TRUE))
  same <- if (is.character(e$expected) && identical(e$expected, 'missing')) is.na(v) else if (is.numeric(e$expected) && is.numeric(v)) !is.na(v) && abs(v - e$expected) < 1e-8 else !is.na(v) && identical(as.character(v), as.character(e$expected))
  if (!isTRUE(same)) fail('Evidence value for "', e$label, '" is ', wr_format_value(v), ', not the expected ', format(e$expected), '.')
  invisible(TRUE)
}
wr_prepare_evidence <- function(ev) {
  if (is.null(ev) || !length(ev)) fail('A record needs at least one evidence reference.')
  lapply(ev, function(e) {
    if (is.null(e$file) || is.null(e$label)) fail('Each evidence item needs file and label.')
    if (is.null(e$path) && is.null(e$count_where) && (is.null(e$field) || (is.null(e$where) && is.null(e$row)))) fail('Evidence "', e$label, '" needs path, count_where, or field with where/row.')
    e$file <- resolve_path(e$file)
    if (!is.null(e$path)) e$path <- as.list(unlist(e$path)); if (!is.null(e$where)) e$where <- as.list(e$where); if (!is.null(e$count_where)) e$count_where <- as.list(e$count_where)
    wr_check_expected(e, wr_read_cell(e))
    list(file = e$file, sha256 = wr_sha(e$file), label = e$label, field = e$field, where = e$where, row = e$row, count_where = e$count_where, path = e$path, expected = e$expected)
  })
}

# ---------------------------------------------------------------- writing (append-only)
wr_files <- function(dir) sort(list.files(dir, pattern = '^WR-.*\\.json$', full.names = TRUE))
wr_candidate_files <- function(dir) { d <- file.path(dir, WR_CANDIDATE_DIR); if (dir.exists(d)) sort(list.files(d, pattern = '^CAND-.*\\.json$', full.names = TRUE)) else character() }

wr_write <- function(dir, rec, prefix) {
  n <- length(if (prefix == 'WR') wr_files(dir) else wr_candidate_files(dir)) + 1L
  rec <- c(list(id = sprintf('%s-%04d-%s', prefix, n, substr(wr_content_hash(rec), 1, 8))), rec)
  rec$content_sha256 <- wr_content_hash(rec)
  d <- if (prefix == 'WR') dir else file.path(dir, WR_CANDIDATE_DIR); dir.create(d, recursive = TRUE, showWarnings = FALSE)
  target <- file.path(d, paste0(rec$id, '.json')); if (file.exists(target)) fail('Record exists and is never overwritten: ', target)
  tmp <- paste0(target, '.tmp'); on.exit(unlink(tmp))
  jsonlite::write_json(rec, tmp, auto_unbox = TRUE, pretty = TRUE, null = 'null', digits = NA)
  if (!identical(wr_content_hash(jsonlite::fromJSON(tmp, simplifyVector = FALSE)), rec$content_sha256)) fail('Record failed its write check.')
  if (!file.rename(tmp, target)) fail('Could not write the record.')
  invisible(rec)
}

wr_body <- function(registry_dir, class, severity, stage, code, scope, text, stage2_dir, stage3_dir, stage4_dir, evidence, source_file, source_locator, supersedes) {
  if (identical(class, 'AUTO_DIAGNOSTIC')) fail('AUTO_DIAGNOSTIC items are computed at report time and cannot be written by hand.')
  if (is.null(class) || !class %in% setdiff(WR_CLASSES, 'AUTO_DIAGNOSTIC')) fail('class must be USER_APPROVED_LIMITATION or ANALYST_NOTE.')
  if (is.null(severity) || !severity %in% WR_SEVERITIES) fail('severity must be one of: ', paste(WR_SEVERITIES, collapse = ', '), '.')
  if (is.null(stage) || !as.character(stage) %in% WR_STAGES) fail('stage must be 1 to 6.')
  if (is.null(scope) || !scope %in% WR_SCOPES) fail('scope must be one of: ', paste(WR_SCOPES, collapse = ', '), '.')
  if (is.null(code) || !grepl('^[A-Za-z0-9_-]+$', code)) fail('code must be a short identifier.')
  if (is.null(text) || !nzchar(trimws(text))) fail('The record text must not be empty.')
  if (scope %in% c('spec', 'model') && is.null(stage3_dir)) fail('Scope ', scope, ' needs --stage3-dir.')
  if (scope == 'model' && is.null(stage4_dir)) fail('Scope model needs --stage4-dir.')
  if (is.null(source_file)) fail('A record needs --source-file.')
  dir <- resolve_path(registry_dir)
  if (path_within(dir, STAGE2_SKILL_ROOT)) fail('The registry directory must be outside the Skill directory.')
  if (file.exists(dir) && !dir.exists(dir)) fail('Registry path exists and is a file: ', dir)
  id <- wr_identity_dirs(stage2_dir, stage3_dir, if (scope == 'model') stage4_dir else NULL)
  existing <- if (dir.exists(dir)) wr_load(dir) else list()
  if (!is.null(supersedes)) {
    ids <- vapply(existing, function(r) r$id, ''); if (!supersedes %in% ids) fail('Record to supersede not found: ', supersedes)
    if (supersedes %in% unlist(lapply(existing, function(r) r$supersedes))) fail('Record already superseded: ', supersedes)
  }
  if (any(vapply(existing, function(r) identical(r$text, enc2utf8(text)) && identical(r$scope, scope) && identical(r$code, code), NA))) fail('An identical record already exists.')
  p <- resolve_path(source_file); if (!file.exists(p)) fail('Source file not found: ', p)
  list(record_version = WR_VERSION, class = class, severity = severity, stage = as.character(stage), code = code, scope = scope,
       input_md5 = id$input_md5, analysis_data_md5 = id$analysis_data_md5,
       spec_hash = if (scope != 'data') id$spec_hash else NULL, approval_id = if (scope != 'data') id$approval_id else NULL,
       model_id = if (scope == 'model') id$model_id else NULL,
       text = enc2utf8(text), evidence = wr_prepare_evidence(evidence), source = list(file = p, sha256 = wr_sha(p), locator = source_locator), supersedes = supersedes)
}
wr_approval <- function(ref) list(by = 'user', ref = enc2utf8(ref), recorded_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'))
wr_require_approval <- function(approved, ref) {
  if (!isTRUE(approved)) fail('A registry record requires the user\'s explicit approval: pass --approved true only after the user confirmed this exact text.')
  if (is.null(ref) || !nzchar(trimws(ref))) fail('A registry record needs --approval-ref (the user\'s confirmation or the approval record).')
}

# A text the user has already confirmed word for word.
wr_annotate <- function(registry_dir, class, severity, stage, code, scope, text, stage2_dir, stage3_dir = NULL, stage4_dir = NULL,
                        evidence = NULL, source_file = NULL, source_locator = NULL, approval_ref = NULL, supersedes = NULL, approved = FALSE) {
  wr_require_approval(approved, approval_ref)
  b <- wr_body(registry_dir, class, severity, stage, code, scope, text, stage2_dir, stage3_dir, stage4_dir, evidence, source_file, source_locator, supersedes)
  b$approved <- wr_approval(approval_ref)
  wr_write(resolve_path(registry_dir), b, 'WR')
}
# A text waiting for the user: never cited in a report.
wr_propose <- function(registry_dir, class, severity, stage, code, scope, text, stage2_dir, stage3_dir = NULL, stage4_dir = NULL,
                       evidence = NULL, source_file = NULL, source_locator = NULL, supersedes = NULL) {
  b <- wr_body(registry_dir, class, severity, stage, code, scope, text, stage2_dir, stage3_dir, stage4_dir, evidence, source_file, source_locator, supersedes)
  dir <- resolve_path(registry_dir)
  if (any(vapply(if (dir.exists(dir)) wr_load_candidates(dir) else list(), function(r) identical(r$text, b$text) && identical(r$code, b$code), NA))) fail('An identical candidate already exists.')
  wr_write(dir, b, 'CAND')
}
wr_approve_candidate <- function(registry_dir, candidate, approval_ref = NULL, approved = FALSE) {
  wr_require_approval(approved, approval_ref)
  dir <- resolve_path(registry_dir); cands <- wr_load_candidates(dir)
  k <- which(vapply(cands, function(r) identical(r$id, candidate), NA))
  if (!length(k)) fail('Candidate not found: ', candidate)
  recs <- wr_load(dir)
  if (candidate %in% unlist(lapply(recs, function(r) r$from_candidate))) fail('Candidate already approved: ', candidate)
  b <- cands[[k]]; wr_check_refs(b)
  b$from_candidate <- b$id; b$id <- NULL; b$content_sha256 <- NULL; b$approved <- wr_approval(approval_ref)
  wr_write(dir, b, 'WR')
}

# ---------------------------------------------------------------- loading and verification
wr_read_record <- function(f) {
  r <- tryCatch(jsonlite::fromJSON(f, simplifyVector = FALSE), error = function(e) fail('Unreadable registry record: ', f))
  if (is.null(r$content_sha256) || !identical(wr_content_hash(r), r$content_sha256)) fail('Registry record failed its integrity check (content changed): ', f)
  if (!identical(paste0(r$id, '.json'), basename(f))) fail('Registry record id does not match its file name: ', f)
  if (!r$class %in% setdiff(WR_CLASSES, 'AUTO_DIAGNOSTIC')) fail('Registry record has an invalid class: ', f)
  r
}
wr_load <- function(dir) lapply(wr_files(dir), function(f) {
  r <- wr_read_record(f)
  if (is.null(r$approved$ref) || !nzchar(r$approved$ref) || !identical(r$approved$by, 'user')) fail('Registry record has no approval: ', f)
  r
})
wr_load_candidates <- function(dir) lapply(wr_candidate_files(dir), wr_read_record)

# Evidence and source files must be exactly those seen at approval.
wr_check_refs <- function(r) {
  for (e in r$evidence) {
    if (!file.exists(e$file)) fail('Evidence file of record ', r$id, ' not found: ', e$file)
    if (!identical(wr_sha(e$file), e$sha256)) fail('Evidence file of record ', r$id, ' changed since approval: ', e$file)
  }
  if (is.null(r$source$file) || !file.exists(r$source$file) || !identical(wr_sha(r$source$file), r$source$sha256)) fail('Source file of record ', r$id, ' is missing or changed since approval: ', r$source$file)
  invisible(TRUE)
}
wr_check_binding <- function(r, identity) {
  if (!identical(r$input_md5, identity$input_md5)) fail('Registry record ', r$id, ' belongs to another dataset (input checksum differs); it cannot be used for this analysis.')
  if (!is.null(r$analysis_data_md5) && !is.null(identity$analysis_data_md5) && !identical(r$analysis_data_md5, identity$analysis_data_md5)) fail('Registry record ', r$id, ' was written for different analysis data (checksum differs).')
  if (!is.null(r$spec_hash) && !is.null(identity$spec_hash) && !identical(r$spec_hash, identity$spec_hash)) fail('Registry record ', r$id, ' was written under another Stage 3 specification (', r$spec_hash, ').')
  if (!is.null(r$approval_id) && !is.null(identity$approval_id) && !identical(r$approval_id, identity$approval_id)) fail('Registry record ', r$id, ' has a different Stage 3 approval (', r$approval_id, ').')
  invisible(TRUE)
}

# Identity, file-hash or approval mismatches stop the report. A record bound to another model is not cited; only its id and reason are listed.
wr_apply <- function(records, identity, candidates = list()) {
  ids <- vapply(records, function(r) r$id, '')
  for (r in c(records, candidates)) { wr_check_binding(r, identity); wr_check_refs(r) }
  for (r in records) if (!is.null(r$supersedes) && !r$supersedes %in% ids) fail('Registry record ', r$id, ' supersedes a missing record: ', r$supersedes)
  dead <- unlist(lapply(records, function(r) r$supersedes)); done <- unlist(lapply(records, function(r) r$from_candidate))
  row <- function(r, why) data.frame(id = r$id, class = r$class, scope = r$scope, model_id = if (is.null(r$model_id)) NA_character_ else r$model_id, reason = why, stringsAsFactors = FALSE)
  applied <- list(); refused <- list()
  for (r in records) {
    why <- if (r$id %in% dead) 'superseded by a later record' else if (identical(r$scope, 'model') && is.null(identity$model_id)) sprintf('bound to model %s; this report has no model', r$model_id)
           else if (identical(r$scope, 'model') && !identical(r$model_id, identity$model_id)) sprintf('bound to model %s, not the model in this report (%s)', r$model_id, identity$model_id)
           else if (identical(r$scope, 'spec') && is.null(identity$spec_hash)) 'bound to a specification; this report has none' else NULL
    if (is.null(why)) applied[[length(applied) + 1L]] <- r else refused[[length(refused) + 1L]] <- row(r, why)
  }
  for (r in candidates) if (!r$id %in% done) refused[[length(refused) + 1L]] <- row(r, 'candidate awaiting the user\'s confirmation; not approved')
  list(applied = applied, refused = if (length(refused)) do.call(rbind, refused) else NULL)
}

# ---------------------------------------------------------------- automatic diagnostics (computed from the stage outputs)
wr_auto_rows <- function(ctx) {
  o <- list(); add <- function(stage, sev, code, scope, text, source) o[[length(o) + 1L]] <<- data.frame(stage = as.character(stage), severity = sev, code = code, scope = scope, text = text, source = source, stringsAsFactors = FALSE)
  d2 <- ctx$d2; lgp <- ctx$lgp
  if (isTRUE(d2$missing_cells > 0)) add(2, 'INFO', 'S2_MISSING_MECHANISM', 'data', 'The missingness mechanism (MCAR/MAR/MNAR) cannot be identified from the missing-value counts.', 'stage 2 summary.json')
  if (identical(ctx$decision, 'processed') && !is.null(lgp)) {
    if (isTRUE(lgp$imputed_cells$total > 0)) add(2, 'LIMITATION', 'S2_SINGLE_IMPUTATION', 'data', paste0('Single imputation (`', lgp$method, '`', if (!is.null(lgp$knn)) paste0(', k = ', lgp$knn$k) else '', '): ', lgp$imputed_cells$total, ' cell(s) imputed (',
      paste(sprintf('%s = %d', names(lgp$imputed_cells$by_variable), unlist(lgp$imputed_cells$by_variable)), collapse = ', '), '). Imputed values are treated as observed in later stages; imputation uncertainty is not represented.'), 'stage 2 preprocessing_log.json')
    if (isTRUE(lgp$rows_removed$count > 0)) add(2, 'LIMITATION', 'S2_ROWS_REMOVED', 'data', paste0(lgp$rows_removed$count, ' row(s) removed before modelling (source rows: ', paste(lgp$rows_removed$source_row_ids, collapse = ', '), '). Results describe the retained rows only.'), 'stage 2 preprocessing_log.json')
  }
  if (length(ctx$co$flags)) add(2, 'WARNING', 'S2_COLLINEARITY', 'data', paste0('Collinearity flags: ', paste(ctx$co$flags, collapse = '; '), '.'), 'stage 2 eda/collinearity.json')
  s3c <- ctx$s3c
  if (!is.null(s3c)) { w <- s3c[s3c$status %in% c('WARNING', 'PAUSE', 'STOP'), ]
    for (i in seq_len(nrow(w))) add(3, if (w$status[i] == 'WARNING') 'WARNING' else 'LIMITATION', w$id[i], 'spec', paste0(w$check[i], ' [', w$status[i], ']: ', sub('\\. Note: .*$', '', w$evidence[i])), 'stage3_checks.csv') }
  mc <- ctx$mc; sel <- ctx$sel
  if (!is.null(mc) && !is.null(sel)) {
    dw <- mc$diagnostic_warnings[mc$G == sel$selected_G]
    if (length(dw) && !is.na(dw) && nzchar(dw)) for (v in strsplit(dw, ' | ', fixed = TRUE)[[1]]) add(4, 'WARNING', sub(':.*$', '', v), 'model', paste0('Selected model: ', v), 'model_comparison.csv')
    if (isTRUE(sel$boundary_optimum)) add(4, 'LIMITATION', 'S4_BOUNDARY_OPTIMUM', 'model', 'The selected G is at the upper search limit; a wider search would need a new Stage 3 approval.', 'selected_model.json')
    if (isFALSE(sel$bic_aic_agree)) add(4, 'INFO', 'S4_BIC_AIC_DISAGREE', 'model', sprintf('BIC selected G = %s and AIC preferred G = %s.', sel$selected_G, sel$aic_selected_G), 'selected_model.json')
  }
  s6 <- ctx$s6; b6 <- ctx$b6; str6 <- ctx$str6
  if (!is.null(s6)) {
    if (!is.null(b6) && nrow(b6) && any(b6$G == s6$selected_G)) add(6, 'WARNING', 'S6_OPTIMA_DISAGREE', 'model', sprintf('Partitions from distinct local optima of the selected G can disagree: ARI between optima as low as %s.', formatC(min(b6$ari_representatives[b6$G == s6$selected_G]), format = 'f', digits = 3)), 'stability_between_optima_ari.csv')
    if (!is.null(s6$stability$bootstrap_subsampling) && grepl('not', s6$stability$bootstrap_subsampling, ignore.case = TRUE)) add(6, 'INFO', 'S6_BOOTSTRAP_NOT_RUN', 'model', paste0('Bootstrap / subsampling: ', s6$stability$bootstrap_subsampling, '.'), 'stage6_summary.json')
  }
  if (!is.null(str6)) for (v in unique(str6$variable)) {
    t <- str6[str6$variable == v, ]; cc <- grep('^component_', names(t), value = TRUE)
    share <- vapply(cc, function(k) if (sum(t[[k]])) max(t[[k]]) / sum(t[[k]]) else NA_real_, numeric(1)); top <- vapply(cc, function(k) t$stratum[which.max(t[[k]])], character(1))
    add(6, 'INFO', 'S6_STRATA', 'model', sprintf('Sampling structure (%s, descriptive): largest share of each component in one stratum - %s.', v, paste(sprintf('%s: %.0f%% in %s', sub('component_', 'component ', cc), 100 * share, top), collapse = '; ')), 'strata_check.csv')
  }
  if (!isTRUE(ctx$dx_only) && !is.null(s6) && !isTRUE(ctx$ex6$available)) add(6, 'INFO', 'S6_EXTERNAL_NOT_PERFORMED', 'model', 'External validation: Not Performed. No external labels were available or provided.', 'external_validation.json')
  if (length(o)) do.call(rbind, o) else NULL
}

# The spec note is what the user approved together with the specification; it is shown verbatim and never edited.
wr_spec_items <- function(s3) {
  if (is.null(s3) || is.null(s3$independence_note) || !nzchar(s3$independence_note)) return(list())
  list(list(id = 'SPEC-independence_note', class = 'USER_APPROVED_LIMITATION', severity = 'LIMITATION', stage = '3', code = 'S3_INDEPENDENCE_NOTE', scope = 'spec', spec_hash = s3$spec_hash,
            text = s3$independence_note, evidence = list(), source = list(file = 'stage3_spec.json', locator = 'independence_note'), approved = list(by = 'user', ref = paste('Stage 3 approval', s3$approval_id))))
}

# ---------------------------------------------------------------- report section
wr_quote <- function(x) paste0('> ', strsplit(gsub('\r', '', x), '\n', fixed = TRUE)[[1]])
wr_record_lines <- function(r) {
  c(sprintf('**%s** [%s] Stage %s, `%s`, scope: %s', r$id, r$severity, r$stage, r$code, r$scope), '', wr_quote(r$text), '',
    if (length(r$evidence)) paste0('- Evidence, read from the file at report time: ', paste(vapply(r$evidence, function(e) paste0(e$label, ' = ', wr_format_value(wr_read_cell(e)), ' (`', basename(dirname(e$file)), '/', basename(e$file), '`)'), ''), collapse = '; '), '.') else NULL,
    sprintf('- Source: `%s` (%s).', basename(r$source$file), if (is.null(r$source$locator)) 'whole file' else r$source$locator),
    sprintf('- Approval: %s', r$approved$ref), '')
}

wr_report_section <- function(registry_dir, identity, ctx, manifest_limits, general) {
  recs <- list(); cands <- list()
  if (!is.null(registry_dir)) { if (!dir.exists(registry_dir)) fail('Warnings registry directory not found: ', registry_dir); recs <- wr_load(registry_dir); cands <- wr_load_candidates(registry_dir) }
  ap <- wr_apply(recs, identity, cands)
  for (r in ap$applied) for (e in r$evidence) wr_check_expected(e, wr_read_cell(e))
  auto <- wr_auto_rows(ctx); spec_items <- wr_spec_items(ctx$s3)
  user <- c(spec_items, Filter(function(r) identical(r$class, 'USER_APPROVED_LIMITATION'), ap$applied)); note <- Filter(function(r) identical(r$class, 'ANALYST_NOTE'), ap$applied)
  L <- c('### 11.1 Automated diagnostics', '', '*Computed from the stage output files for this analysis.*', '',
         if (is.null(auto)) '- None.' else sprintf('- [%s] Stage %s, `%s`: %s', auto$severity, auto$stage, auto$code, auto$text),
         '', '### 11.2 User-approved limitations', '', '*Quoted verbatim from the approved specification or a confirmed registry record.*', '',
         if (length(user)) unlist(lapply(user, wr_record_lines)) else c('- None.', ''),
         '### 11.3 Analyst notes', '', '*Interpretations confirmed by the user. They are not established statistical results.*', '',
         if (length(note)) unlist(lapply(note, wr_record_lines)) else c('- None.', ''),
         '### 11.4 Records not cited', '', '*Bound to another model, superseded, or awaiting confirmation. Their content is deliberately not reproduced here.*', '',
         if (is.null(ap$refused)) '- None.' else sprintf('- `%s` (%s): %s.', ap$refused$id, ap$refused$class, ap$refused$reason), '')
  if (length(manifest_limits)) L <- c(L, '### Limitations from the report manifest (not verified by the registry)', '', '*Free text from the manifest, with no recorded source, approval or identity binding.*', '', paste('-', unlist(manifest_limits)), '')
  L <- c(L, '### 11.5 General method caveats', '', paste('-', general))
  item <- function(r, status) data.frame(id = r$id, class = r$class, severity = r$severity, stage = r$stage, code = r$code, scope = r$scope, status = status,
    input_md5 = identity$input_md5, spec_hash = if (is.null(r$spec_hash)) NA_character_ else r$spec_hash, model_id = if (is.null(r$model_id)) NA_character_ else r$model_id, text = r$text,
    source = r$source$file, approval = r$approved$ref, reason = NA_character_, stringsAsFactors = FALSE)
  rows <- lapply(c(spec_items, ap$applied), item, status = 'APPLIED')
  if (!is.null(auto)) rows <- c(rows, lapply(seq_len(nrow(auto)), function(i) data.frame(id = sprintf('AUTO-%03d', i), class = 'AUTO_DIAGNOSTIC', severity = auto$severity[i], stage = auto$stage[i], code = auto$code[i], scope = auto$scope[i], status = 'APPLIED',
    input_md5 = identity$input_md5, spec_hash = if (is.null(identity$spec_hash)) NA_character_ else identity$spec_hash, model_id = if (auto$scope[i] == 'model' && !is.null(identity$model_id)) identity$model_id else NA_character_, text = auto$text[i], source = auto$source[i], approval = NA_character_, reason = NA_character_, stringsAsFactors = FALSE)))
  if (!is.null(ap$refused)) rows <- c(rows, lapply(seq_len(nrow(ap$refused)), function(i) data.frame(id = ap$refused$id[i], class = ap$refused$class[i], severity = NA_character_, stage = NA_character_, code = NA_character_, scope = ap$refused$scope[i], status = 'NOT_CITED',
    input_md5 = identity$input_md5, spec_hash = NA_character_, model_id = ap$refused$model_id[i], text = NA_character_, source = NA_character_, approval = NA_character_, reason = ap$refused$reason[i], stringsAsFactors = FALSE)))
  list(lines = L, snapshot = if (length(rows)) do.call(rbind, rows) else NULL, n_applied = length(ap$applied), n_refused = if (is.null(ap$refused)) 0L else nrow(ap$refused),
       files = if (is.null(registry_dir)) character() else c(wr_files(registry_dir), wr_candidate_files(registry_dir), unlist(lapply(ap$applied, function(r) c(r$source$file, vapply(r$evidence, function(e) e$file, ''))))))
}

# ---------------------------------------------------------------- CLI
wr_cli <- function(argv) {
  if (!length(argv)) fail('Usage: warnings_registry.R annotate|propose|approve|list --registry-dir <dir> ...')
  cmd <- argv[1]; rest <- argv[-1]
  if (length(rest) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list(); for (i in seq(1L, length(rest), by = 2L)) { if (!startsWith(rest[i], '--')) fail('Expected --key, received: ', rest[i]); a[[substring(rest[i], 3L)]] <- rest[i + 1L] }
  common <- c('registry-dir', 'class', 'severity', 'stage', 'code', 'scope', 'text', 'text-file', 'stage2-dir', 'stage3-dir', 'stage4-dir', 'evidence', 'source-file', 'source-locator', 'supersedes')
  allowed <- list(annotate = c(common, 'approval-ref', 'approved'), propose = common, approve = c('registry-dir', 'candidate', 'approval-ref', 'approved'), list = c('registry-dir', 'stage2-dir', 'stage3-dir', 'stage4-dir'))
  if (!cmd %in% names(allowed)) fail('Unknown command "', cmd, '". Commands: ', paste(names(allowed), collapse = ', '))
  bad <- setdiff(names(a), allowed[[cmd]]); if (length(bad)) fail('Unknown option(s) for ', cmd, ': --', paste(bad, collapse = ', --'))
  miss <- setdiff(if (cmd == 'approve') c('registry-dir', 'candidate') else c('registry-dir', 'stage2-dir'), names(a)); if (length(miss)) fail('Missing settings: --', paste(miss, collapse = ', --'))
  if (cmd == 'approve') { r <- wr_approve_candidate(a[['registry-dir']], a$candidate, a[['approval-ref']], approved = identical(a$approved, 'true')); cat('Recorded:', r$id, '\n'); return(invisible()) }
  if (cmd == 'list') {
    dir <- resolve_path(a[['registry-dir']]); if (!dir.exists(dir)) fail('Warnings registry directory not found: ', dir)
    ap <- wr_apply(wr_load(dir), wr_identity_dirs(a[['stage2-dir']], a[['stage3-dir']], a[['stage4-dir']]), wr_load_candidates(dir))
    for (r in ap$applied) cat(sprintf('[%s] %s %s Stage %s %s: %s\n', r$severity, r$class, r$id, r$stage, r$code, r$text))
    if (!is.null(ap$refused)) cat(sprintf('NOT CITED %s: %s\n', ap$refused$id, ap$refused$reason), sep = '')
    if (!length(ap$applied) && is.null(ap$refused)) cat('No records.\n')
    return(invisible())
  }
  txt <- if (!is.null(a[['text-file']])) paste(readLines(resolve_path(a[['text-file']]), warn = FALSE, encoding = 'UTF-8'), collapse = '\n') else a$text
  ev <- if (is.null(a$evidence)) NULL else jsonlite::fromJSON(resolve_path(a$evidence), simplifyVector = FALSE)
  r <- if (cmd == 'annotate') wr_annotate(a[['registry-dir']], a$class, a$severity, a$stage, a$code, a$scope, txt, a[['stage2-dir']], a[['stage3-dir']], a[['stage4-dir']], ev, a[['source-file']], a[['source-locator']], a[['approval-ref']], a$supersedes, approved = identical(a$approved, 'true'))
       else wr_propose(a[['registry-dir']], a$class, a$severity, a$stage, a$code, a$scope, txt, a[['stage2-dir']], a[['stage3-dir']], a[['stage4-dir']], ev, a[['source-file']], a[['source-locator']], a$supersedes)
  cat(if (cmd == 'annotate') 'Recorded:' else 'Candidate (not approved):', r$id, '\n')
}
if (sys.nframe() == 0L) tryCatch(wr_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
