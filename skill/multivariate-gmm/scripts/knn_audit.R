#!/usr/bin/env Rscript
# Replays the existing KNN imputation of a finished Stage 2 run and writes its donor audit to a new folder.
# Every source check runs first, and an audit is written only if the replay reproduces processed_data.csv.
# The Stage 2 folder and the input file are read only.
# Usage: Rscript knn_audit.R replay --stage2-dir <dir> --output <new dir> [--input <file>]
suppressPackageStartupMessages(library(jsonlite))

ka_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
KA_SCRIPT_DIR <- dirname(ka_script_path())
if (!exists('knn_impute', inherits = TRUE)) source(file.path(KA_SCRIPT_DIR, 'data_stage2.R'), local = TRUE)
if (!exists('skill_sha256', inherits = TRUE)) source(file.path(KA_SCRIPT_DIR, 'hash_utils.R'), local = TRUE) # Cowork release: SHA-256 on R >= 4.1

ka_hashes <- function(d) { f <- sort(list.files(d, recursive = TRUE, full.names = TRUE)); setNames(unname(tools::md5sum(f)), f) }
# processed_data.csv stores 15 significant digits, so values are compared at that precision.
ka_same <- function(a, b) sprintf('%.15g', a) == sprintf('%.15g', b)

knn_replay <- function(stage2_dir, output, input = NULL) {
  src <- resolve_path(stage2_dir); out <- resolve_path(output)
  if (!dir.exists(src)) fail('Stage 2 directory not found: ', src)
  need <- file.path(src, c('run_config.json', 'preprocessing_log.json', 'processed_data.csv', 'variable_missing.csv'))
  if (any(!file.exists(need))) fail('Stage 2 directory incomplete, missing: ', paste(basename(need[!file.exists(need)]), collapse = ', '))
  if (path_within(out, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (path_within(out, src)) fail('Output path is inside the Stage 2 directory, which is read-only for this module.')
  if (file.exists(out) && !dir.exists(out)) fail('Output path exists and is a file: ', out)
  if (dir.exists(out) && length(list.files(out, all.files = TRUE, no.. = TRUE))) fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', out)
  rc <- jsonlite::fromJSON(need[1], simplifyVector = TRUE); lg <- jsonlite::fromJSON(need[2], simplifyVector = TRUE)
  if (!identical(rc$method, 'knn') || !identical(lg$method, 'knn')) fail('This Stage 2 run did not use KNN (method: ', rc$method, ').')
  k <- as.integer(rc$k); if (!identical(k, as.integer(lg$knn$k))) fail('k differs between run_config.json and preprocessing_log.json.')
  cols <- as.character(rc$columns); if (!identical(cols, as.character(lg$variables))) fail('Analysis columns differ between run_config.json and preprocessing_log.json.')
  p <- resolve_path(if (is.null(input)) rc$input else input)
  if (!file.exists(p)) fail('Input file not found: ', p)
  if (!identical(unname(tools::md5sum(p)), lg$input$md5)) fail('Input file hash differs from the Stage 2 log: ', p)
  h0 <- ka_hashes(src)
  raw <- read.csv(p, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''), fileEncoding = 'UTF-8-BOM')
  if (nrow(raw) != lg$input$n_rows) fail('Input has ', nrow(raw), ' rows; the Stage 2 log has ', lg$input$n_rows, '.')
  if (!all(cols %in% names(raw))) fail('Input lacks analysis columns: ', paste(setdiff(cols, names(raw)), collapse = ', '))
  x <- raw[, cols, drop = FALSE]; if (!all(vapply(x, is.numeric, NA))) fail('Selected columns are not numeric in the input.')
  miss <- matrix(as.matrix(is.na(x)), nrow(x), ncol(x)); vm <- read.csv(need[4], check.names = FALSE, stringsAsFactors = FALSE)
  if (!identical(as.character(vm$variable), cols) || !all(vm$missing_count == colSums(miss))) fail('Missing-value positions differ from the Stage 2 record (variable_missing.csv).')
  all_miss <- which(rowSums(miss) == ncol(x))
  logged_am <- as.integer(unlist(lg$all_missing_rows$source_row_ids)); logged_rm <- as.integer(unlist(lg$rows_removed$source_row_ids))
  if (!identical(all_miss, logged_am)) fail('All-missing rows differ from the Stage 2 log.')
  if (!identical(all_miss, logged_rm)) fail('Removed rows differ from the Stage 2 log; KNN removes only all-missing rows.')
  idx <- setdiff(seq_len(nrow(x)), all_miss)
  pd <- read.csv(need[3], check.names = FALSE)
  if (!identical(names(pd), c('source_row_id', cols))) fail('processed_data.csv does not have the analysis columns in order.')
  if (!identical(as.integer(pd$source_row_id), as.integer(idx))) fail('source_row_id in processed_data.csv does not match the retained input rows.')
  if (!identical(as.integer(unlist(lg$imputed_cells$by_variable[cols])), as.integer(colSums(miss[idx, , drop = FALSE])))) fail('Imputed-cell counts differ from the Stage 2 log.')
  res <- knn_impute(x, idx, k)
  if (nrow(res$failures)) fail('The replay could not impute ', nrow(res$failures), ' cell(s) that the Stage 2 run imputed.')
  if (!identical(as.integer(res$cells_fewer_than_k_donors), as.integer(lg$knn$cells_with_fewer_than_k_donors))) fail('The count of cells with fewer than k donors differs from the Stage 2 log.')
  n_obs_diff <- 0L; n_imp_diff <- 0L
  for (j in seq_along(cols)) { m <- miss[idx, j]; same <- ka_same(res$processed[[j]], pd[[cols[j]]]); n_obs_diff <- n_obs_diff + sum(!same & !m); n_imp_diff <- n_imp_diff + sum(!same & m) }
  if (n_obs_diff) fail('Replay stopped: ', n_obs_diff, ' observed cell(s) in processed_data.csv differ from the input.')
  if (n_imp_diff) fail('Replay stopped: ', n_imp_diff, ' imputed value(s) in processed_data.csv are not reproduced.')
  meta <- list(mode = 'replay', k = k, stage2_script_version = STAGE2_VERSION, original_script_version = lg$script_version, source_stage2_dir = src,
               source_hashes_md5 = as.list(setNames(unname(h0), basename(names(h0)))[basename(need)]),
               input = list(path = p, md5 = lg$input$md5, sha256 = unname(skill_sha256(p))),
               verified_before_audit = list(input_hash = TRUE, columns = TRUE, k = TRUE, missing_positions = TRUE, removed_rows = TRUE, source_row_id_mapping = TRUE,
                                            observed_cells_equal_at_15_significant_digits = TRUE, imputed_values_equal_at_15_significant_digits = TRUE, n_cells_compared = nrow(pd) * length(cols)))
  stage_and_commit(out, function(dir) knn_audit_write(res$audit, dir, meta), function(dir) {
    bad <- KNN_AUDIT_FILES[!file.exists(file.path(dir, KNN_AUDIT_FILES))]; if (length(bad)) fail('Audit output incomplete: ', paste(bad, collapse = ', '))
    if (!identical(ka_hashes(src), h0)) fail('The Stage 2 directory changed during the replay.')
  })
  list(status = 'REPLAYED', output = out, audit = res$audit, n_cells = nrow(res$audit$cells))
}

ka_cli <- function(argv) {
  if (!length(argv) || argv[1] != 'replay') fail('Usage: knn_audit.R replay --stage2-dir <dir> --output <new dir> [--input <file>]')
  rest <- argv[-1]; if (length(rest) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list(); for (i in seq(1L, length(rest), by = 2L)) { if (!startsWith(rest[i], '--')) fail('Expected --key, received: ', rest[i]); a[[substring(rest[i], 3L)]] <- rest[i + 1L] }
  bad <- setdiff(names(a), c('stage2-dir', 'output', 'input')); if (length(bad)) fail('Unknown option(s): --', paste(bad, collapse = ', --'))
  if (is.null(a[['stage2-dir']]) || is.null(a$output)) fail('--stage2-dir and --output are required.')
  r <- knn_replay(a[['stage2-dir']], a$output, a$input)
  cat(sprintf('Replay matched processed_data.csv. Audited %d imputed cell(s).\nOutput: %s\n', r$n_cells, r$output))
}
if (sys.nframe() == 0L) tryCatch(ka_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
