#!/usr/bin/env Rscript
# Data import and read-only preview, used before a workflow exists.
#   preview: reads the file and prints what it finds. It writes nothing and converts nothing.
#   import:  after the user confirms the settings, writes a standardized UTF-8 CSV and a record to a new folder.
# Missing-value markers are never assumed: --na is required for import, and the file is parsed as text so values are kept verbatim.
# Usage: Rscript data_import.R preview --input <file> --encoding <enc> [--header true|false] [--sep ...] [--na "?,NA,<blank>"]
#        Rscript data_import.R import --input <file> --analysis <name> --header ... --sep ... --encoding ... --na ... --approval-ref "..." --approved true
suppressPackageStartupMessages(library(jsonlite))

di_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
DI_SCRIPT_DIR <- dirname(di_script_path())
if (!exists('resolve_path', inherits = TRUE)) source(file.path(DI_SCRIPT_DIR, 'data_stage2.R'), local = TRUE)
if (!exists('skill_sha256', inherits = TRUE)) source(file.path(DI_SCRIPT_DIR, 'hash_utils.R'), local = TRUE) # Cowork release: SHA-256 on R >= 4.1

DI_VERSION <- '0.1.0'
DI_SEPS <- c(comma = ',', semicolon = ';', tab = '\t', pipe = '|')
DI_BLANK <- '<blank>'; DI_WS <- '<whitespace>'
DI_COMMON_MARKERS <- c('?', '-', '.', 'N/A', 'n/a', 'null', 'NULL') # shown only; never converted unless listed in --na
DI_NAME_RE <- '^[A-Za-z0-9][A-Za-z0-9_.-]*$'

di_hash <- function(f) { h <- unname(skill_sha256(f)); if (anyNA(h)) fail('Cannot compute the SHA-256 of a file that does not exist: ', f[is.na(h)][1]); h }

# ---------------------------------------------------------------- reading
di_input_path <- function(input) { p <- resolve_path(input); if (!file.exists(p) || dir.exists(p)) fail('Input file not found: ', p); if (file.size(p) == 0) fail('Input file is empty: ', p); p }
di_check_encoding <- function(enc) {
  if (identical(enc, 'UTF-8-BOM')) return('UTF-8')
  if (!toupper(enc) %in% toupper(iconvlist())) fail('Unknown encoding "', enc, '". See iconvlist() for the names available on this system.')
  enc
}
# Returns UTF-8 lines. Invalid bytes stop the read with the first offending line.
di_read_lines <- function(path, encoding) {
  enc <- di_check_encoding(encoding)
  b <- readBin(path, 'raw', file.size(path))
  if (length(b) >= 3 && identical(as.integer(b[1:3]), c(239L, 187L, 191L)) && toupper(enc) == 'UTF-8') b <- b[-(1:3)]
  if (any(b == as.raw(0))) fail('The file contains NUL bytes (it may be UTF-16 or binary), which this importer does not read.')
  x <- strsplit(rawToChar(b), '\n', fixed = TRUE, useBytes = TRUE)[[1]]
  if (toupper(enc) == 'UTF-8') { ok <- validUTF8(x); Encoding(x[ok]) <- 'UTF-8' }
  else { y <- suppressWarnings(iconv(x, from = enc, to = 'UTF-8')); ok <- !is.na(y); x[ok] <- y[ok] }
  if (!all(ok)) fail('The file is not valid ', enc, ': first invalid bytes on line ', which(!ok)[1], ' of ', length(x), ' (', sum(!ok), ' line(s) affected). Set --encoding to the file\'s real encoding.')
  x <- sub('\r$', '', x)
  while (length(x) && !nzchar(x[length(x)])) x <- x[-length(x)]
  if (!length(x)) fail('The file has no content.')
  x
}
di_counts <- function(lines, sep) count.fields(textConnection(lines, encoding = 'UTF-8'), sep = sep, quote = '"', comment.char = '', blank.lines.skip = FALSE)
di_sep_candidates <- function(lines) {
  s <- vapply(DI_SEPS, function(ch) { n <- tryCatch(di_counts(lines, ch), error = function(e) NA); n <- n[!is.na(n)]; length(n) > 0 && n[1] > 1 && all(n == n[1]) }, NA)
  names(DI_SEPS)[s]
}
di_parse <- function(lines, sep_name) {
  if (!sep_name %in% names(DI_SEPS)) fail('sep must be one of: ', paste(names(DI_SEPS), collapse = ', '), '.')
  sep <- DI_SEPS[[sep_name]]
  n <- di_counts(lines, sep); k <- n[!is.na(n)][1]
  bad <- which(!is.na(n) & n != k)
  cand <- di_sep_candidates(lines)
  if (length(bad)) fail('Rows have different numbers of fields with sep = ', sep_name, ': line 1 has ', k, ', line ', bad[1], ' has ', n[bad[1]], ' (', length(bad), ' line(s) differ). Separators consistent across lines: ', if (length(cand)) paste(cand, collapse = ', ') else 'none', '.')
  if (k < 2L) fail('Only one column was found with sep = ', sep_name, '. Separators consistent across lines: ', if (length(cand)) paste(cand, collapse = ', ') else 'none', '.')
  d <- read.table(text = lines, sep = sep, quote = '"', header = FALSE, colClasses = 'character', na.strings = character(), comment.char = '', strip.white = FALSE,
                  blank.lines.skip = FALSE, fill = FALSE, stringsAsFactors = FALSE, encoding = 'UTF-8', check.names = FALSE)
  m <- as.matrix(d); dimnames(m) <- NULL; m[is.na(m)] <- ''
  if (nrow(m) != sum(!is.na(n))) fail('The file has ', sum(!is.na(n)), ' records but ', nrow(m), ' were parsed; nothing was imported.')
  m
}
di_name_problems <- function(n) {
  p <- character()
  if (any(!nzchar(trimws(n)))) p <- c(p, sprintf('empty column name at position %s', paste(which(!nzchar(trimws(n))), collapse = ', ')))
  d <- unique(n[duplicated(n) & nzchar(trimws(n))]); if (length(d)) p <- c(p, sprintf('duplicate column name(s): %s', paste(d, collapse = ', ')))
  w <- n[nzchar(trimws(n)) & n != trimws(n)]; if (length(w)) p <- c(p, sprintf('column name(s) with leading or trailing spaces: "%s"', paste(w, collapse = '", "')))
  cm <- n[grepl(',', n, fixed = TRUE)]; if (length(cm)) p <- c(p, sprintf('column name(s) containing a comma, which --columns cannot select: "%s"', paste(cm, collapse = '", "')))
  p
}
di_tokens <- function(na) {
  if (is.null(na)) return(NULL)
  if (identical(trimws(na), 'none')) return(character())
  t <- trimws(strsplit(na, ',', fixed = TRUE)[[1]])
  if (!length(t) || any(!nzchar(t))) fail('--na needs a comma-separated list, for example "?,NA,<blank>", or "none".')
  t
}
di_is_num <- function(v) { z <- trimws(v); !is.na(suppressWarnings(as.numeric(z))) | z %in% c('NaN', 'Inf', '-Inf') }
di_token_mask <- function(v, tokens) v %in% setdiff(tokens, c(DI_BLANK, DI_WS)) | (DI_BLANK %in% tokens & !nzchar(v)) | (DI_WS %in% tokens & nzchar(v) & !nzchar(trimws(v)))
di_table <- function(v, max = 5L) { if (!length(v)) return(''); t <- sort(table(v), decreasing = TRUE); paste(sprintf('"%s" (%d)', names(t)[seq_len(min(max, length(t)))], as.integer(t)[seq_len(min(max, length(t)))]), collapse = ', ') }

di_profile <- function(m, nm, tokens) {
  do.call(rbind, lapply(seq_along(nm), function(j) {
    v <- m[, j]; bl <- !nzchar(v); ws <- nzchar(v) & !nzchar(trimws(v)); tk <- if (is.null(tokens)) rep(FALSE, length(v)) else di_token_mask(v, tokens)
    obs <- !bl & !ws & !tk; nu <- di_is_num(v) & obs; non <- v[obs & !nu]
    ty <- if (!any(obs)) 'empty' else if (!length(non)) 'numeric' else if (any(nu)) 'mixed' else 'text'
    cm <- vapply(DI_COMMON_MARKERS, function(x) sum(v == x), 0L); cm <- cm[cm > 0]
    data.frame(column = nm[j], type = ty, n_numeric = sum(nu), n_non_numeric = length(non), n_blank = sum(bl), n_whitespace_only = sum(ws), n_literal_NA = sum(v == 'NA'),
               other_markers = if (length(cm)) paste(sprintf('"%s" (%d)', names(cm), cm), collapse = ', ') else '', n_declared_missing = sum(tk), n_inf = sum(trimws(v) %in% c('Inf', '-Inf')), n_nan = sum(trimws(v) == 'NaN'),
               non_numeric_values = if (ty == 'mixed') di_table(non) else '', stringsAsFactors = FALSE, check.names = FALSE)
  }))
}
di_names_from <- function(m, header, names_arg) {
  body <- if (header) m[-1, , drop = FALSE] else m
  nm <- if (!is.null(names_arg)) names_arg else if (header) m[1, ] else paste0('V', seq_len(ncol(m)))
  if (length(nm) != ncol(m)) fail('The file has ', ncol(m), ' columns, but ', length(nm), ' names were given.')
  list(names = unname(nm), body = body)
}

# ---------------------------------------------------------------- preview (writes nothing)
di_preview <- function(input, header = NULL, sep = NULL, encoding = NULL, na = NULL, n_head = 5L) {
  if (is.null(encoding)) fail('--encoding is required: the file\'s encoding is never guessed.')
  p <- di_input_path(input); lines <- di_read_lines(p, encoding); cand <- di_sep_candidates(lines)
  used <- if (!is.null(sep)) sep else if (length(cand) == 1L) cand else if ('comma' %in% cand) 'comma' else if (length(cand)) cand[1] else 'comma'
  m <- di_parse(lines, used)
  hdr <- if (is.null(header)) FALSE else header # unspecified: the first line is shown as data, and nothing is assumed
  s <- di_names_from(m, hdr, NULL); if (!nrow(s$body)) fail('The file has a header but no data rows.')
  prof <- di_profile(s$body, s$names, di_tokens(na))
  w <- character()
  if (is.null(header)) w <- c(w, sprintf('Header not specified: the first line is shown as data and nothing was assumed (its fields are %s). Set --header true or false.', if (all(di_is_num(m[1, ]))) 'all numeric' else 'not all numeric'))
  if (hdr) w <- c(w, di_name_problems(s$names))
  if (is.null(sep) && length(cand) != 1L) w <- c(w, sprintf('Separator is not certain. Consistent separators: %s. Shown with: %s.', if (length(cand)) paste(cand, collapse = ', ') else 'none', used))
  mix <- prof[prof$type == 'mixed', ]
  if (nrow(mix)) w <- c(w, sprintf('Column "%s" has numeric values but also non-numeric ones: %s. It would be read as text unless these are declared with --na.', mix$column, mix$non_numeric_values))
  inf <- prof[prof$n_inf + prof$n_nan > 0, ]; if (nrow(inf)) w <- c(w, sprintf('Column "%s" contains Inf or NaN (%d). These are not missing-value markers.', inf$column, inf$n_inf + inf$n_nan))
  invisible(list(status = 'PREVIEW', input = p, size_bytes = file.size(p), encoding = encoding, sep = used, sep_candidates = cand, header = if (is.null(header)) NA else header, header_given = !is.null(header), n_rows = nrow(s$body), n_columns = ncol(s$body),
                 columns = s$names, profile = prof, head = setNames(as.data.frame(s$body[seq_len(min(n_head, nrow(s$body))), , drop = FALSE], stringsAsFactors = FALSE), make.unique(ifelse(nzchar(s$names), s$names, 'unnamed'))), warnings = w, simulated_na = na))
}
di_print_preview <- function(r) {
  cat(sprintf('Input: %s (%d bytes)\nEncoding: %s valid\nSeparator: %s (consistent: %s)\nHeader: %s\nSize: %d rows x %d columns\n', r$input, r$size_bytes, r$encoding, r$sep, if (length(r$sep_candidates)) paste(r$sep_candidates, collapse = ', ') else 'none', if (r$header_given) r$header else 'not specified (first line shown as data)', r$n_rows, r$n_columns))
  if (!is.null(r$simulated_na)) cat('Simulated --na (nothing is converted):', r$simulated_na, '\n')
  cat('\nColumns\n'); print(r$profile[, c('column', 'type', 'n_numeric', 'n_non_numeric', 'n_blank', 'n_whitespace_only', 'n_literal_NA', 'other_markers', 'n_declared_missing')], row.names = FALSE, right = FALSE)
  cat('\nFirst rows (as text)\n'); print(r$head, row.names = FALSE, right = FALSE)
  cat('\nWarnings\n'); if (length(r$warnings)) cat(paste0('- ', r$warnings, '\n'), sep = '') else cat('- None\n')
  cat('\nNothing was written or converted. Next: confirm the settings and the analysis variables, then run import.\n')
}

# ---------------------------------------------------------------- import
di_quote <- function(v) { q <- !is.na(v) & grepl('[,"\n\r]', v); v[q] <- paste0('"', gsub('"', '""', v[q], fixed = TRUE), '"'); v[is.na(v)] <- 'NA'; v }
di_write_csv <- function(m, nm, file) {
  q <- m; for (j in seq_len(ncol(m))) q[, j] <- di_quote(m[, j])
  rows <- apply(q, 1, paste, collapse = ',')
  writeBin(charToRaw(enc2utf8(paste0(paste(c(paste(di_quote(nm), collapse = ','), rows), collapse = '\n'), '\n'))), file)
}
# Reads a CSV the way Stages 2-6 do, as text, so cells can be compared one by one.
di_read_stage_text <- function(f) {
  d <- read.csv(f, check.names = FALSE, stringsAsFactors = FALSE, colClasses = 'character', na.strings = c('NA', ''), fileEncoding = 'UTF-8-BOM')
  m <- as.matrix(d); dimnames(m) <- NULL; list(names = names(d), m = m)
}
# Cell-by-cell comparison. Equal numbers written differently (88.60 and 88.6) are counted apart from identical text and from real differences.
di_compare_cells <- function(a, b) {
  if (!identical(dim(a), dim(b))) fail('Cell comparison needs matrices of the same size.')
  na_a <- is.na(a); na_b <- is.na(b); both <- !na_a & !na_b
  same <- both; same[both] <- a[both] == b[both]
  diff <- both & !same; x <- suppressWarnings(as.numeric(a[diff])); y <- suppressWarnings(as.numeric(b[diff]))
  eqn <- !is.na(x) & !is.na(y) & x == y
  list(n_cells = length(a), identical_text = sum(same), same_number_different_text = sum(eqn), different = sum(!eqn), missing_mismatch = sum(na_a != na_b), both_missing = sum(na_a & na_b))
}
di_analysis_dir <- function(analysis, results_dir) {
  if (is.null(analysis) || !grepl(DI_NAME_RE, analysis) || grepl('..', analysis, fixed = TRUE)) fail('analysis must be a simple name (letters, digits, "_", "-", "."), not a path.')
  d <- file.path(resolve_path(results_dir), analysis)
  if (path_within(d, STAGE2_SKILL_ROOT)) fail('Results must be outside the Skill directory.')
  d
}
di_new_id <- function(parent, prefix) { stamp <- format(Sys.time(), '%Y%m%d-%H%M%S', tz = 'UTC'); k <- 1L; while (file.exists(file.path(parent, sprintf('%s-%s-%02d', prefix, stamp, k)))) k <- k + 1L; sprintf('%s-%s-%02d', prefix, stamp, k) }

di_import <- function(input, analysis, header, sep, encoding, na, names_arg = NULL, approved = FALSE, approval_ref = NULL, results_dir = 'results') {
  if (!isTRUE(approved)) refuse('Import requires the user\'s explicit approval of these settings: pass --approved true only after the user confirmed them.')
  if (is.null(approval_ref) || !nzchar(trimws(approval_ref))) refuse('Import needs --approval-ref (the user\'s confirmation).')
  if (!is.logical(header) || length(header) != 1L || is.na(header)) fail('--header must be true or false.')
  if (is.null(sep)) fail('--sep is required.'); if (is.null(encoding)) fail('--encoding is required.'); if (is.null(na)) fail('--na is required: list the missing-value markers, or use "none".')
  tokens <- di_tokens(na); root <- di_analysis_dir(analysis, results_dir); p <- di_input_path(input); h0 <- di_hash(p)
  m <- di_parse(di_read_lines(p, encoding), sep); s <- di_names_from(m, header, names_arg); body <- s$body; nm <- s$names
  if (!nrow(body)) fail('The file has a header but no data rows.')
  np <- di_name_problems(nm); if (length(np)) fail('Column names cannot be used: ', paste(np, collapse = '; '), '. Provide all names with --names or --names-file.')
  prof <- di_profile(body, nm, tokens)
  conv <- vapply(seq_along(nm), function(j) sum(di_token_mask(body[, j], tokens)), 0L)
  out <- body; for (j in seq_along(nm)) out[di_token_mask(body[, j], tokens), j] <- NA_character_
  left <- vapply(seq_along(nm), function(j) { v <- out[, j]; sum(!is.na(v) & (!nzchar(trimws(v)) | trimws(v) == 'NA')) }, 0L)
  if (any(left > 0)) pause('IMPORT_UNDECLARED_MISSING_LIKE', paste0('Cells that are blank, only spaces or the literal text NA are not listed in --na, and later stages would read them as missing:\n', paste(sprintf('  %s: %d', nm[left > 0], left[left > 0]), collapse = '\n'), '\nDecide: add them to --na (use <blank>, <whitespace> or NA), or correct the source file. Nothing was written.'))
  id <- di_new_id(file.path(root, 'imports'), 'I'); output <- file.path(root, 'imports', id)
  rec <- list(record_type = 'data_import', script_version = DI_VERSION, import_id = id, analysis = analysis, created_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
              source = list(path = p, sha256 = h0, md5 = unname(tools::md5sum(p)), size_bytes = file.size(p)),
              settings = list(header = header, sep = sep, encoding = encoding, na_tokens = I(tokens), names_source = if (!is.null(names_arg)) 'provided by the user' else if (header) 'first line of the file' else 'generated V1..Vp'),
              n_rows = nrow(out), n_columns = ncol(out), columns = I(nm),
              conversions = list(total_cells_set_to_missing = sum(conv), by_column = as.list(setNames(conv, nm))), column_types_after_import = as.list(setNames(prof$type, nm)),
              approval = list(by = 'user', ref = enc2utf8(approval_ref)), r_version = R.version.string)
  writer <- function(dir) {
    std <- file.path(dir, 'standardized.csv'); di_write_csv(out, nm, std)
    b <- di_read_stage_text(std)
    if (!identical(b$names, nm)) fail('Validation failed: column names or their order changed in the standardized file.')
    if (!identical(dim(b$m), dim(out))) fail('Validation failed: the standardized file has ', nrow(b$m), ' rows and ', ncol(b$m), ' columns; the source has ', nrow(out), ' and ', ncol(out), '.')
    cmp <- di_compare_cells(out, b$m)
    if (cmp$different || cmp$missing_mismatch || cmp$same_number_different_text) fail('Validation failed: the standardized file does not reproduce the imported cells (different ', cmp$different, ', missing mismatch ', cmp$missing_mismatch, ', reformatted numbers ', cmp$same_number_different_text, ').')
    typed <- read.csv(std, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''), fileEncoding = 'UTF-8-BOM')
    is_num <- vapply(typed, is.numeric, NA); bad_ty <- nm[(prof$type == 'numeric') != is_num & prof$type != 'empty']
    if (length(bad_ty)) fail('Validation failed: column type differs from the import profile: ', paste(bad_ty, collapse = ', '), '.')
    rec$standardized <- list(file = 'standardized.csv', sha256 = di_hash(std), md5 = unname(tools::md5sum(std)), encoding = 'UTF-8', missing_token = 'NA')
    rec$validation <- c(list(result = 'passed', rows_source = nrow(out), rows_standardized = nrow(b$m), columns_source = ncol(out), columns_standardized = ncol(b$m), names_and_order_identical = TRUE,
                             column_types_as_read_by_stage2 = as.list(setNames(vapply(typed, function(v) class(v)[1], ''), nm))), cmp)
    write_json_file(rec, file.path(dir, 'import_record.json'))
  }
  validator <- function(dir) { if (!all(file.exists(file.path(dir, c('standardized.csv', 'import_record.json'))))) fail('Import output incomplete.'); if (!identical(di_hash(p), h0)) fail('The source file changed during import.') }
  stage_and_commit(output, writer, validator)
  list(status = 'IMPORTED', output = output, record = file.path(output, 'import_record.json'), standardized = file.path(output, 'standardized.csv'), n_rows = nrow(out), n_columns = ncol(out), cells_set_to_missing = sum(conv), profile = prof)
}

di_cli <- function(argv) {
  if (!length(argv)) fail('Usage: data_import.R preview|import --input <file> ...')
  cmd <- argv[1]; rest <- argv[-1]
  if (length(rest) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list(); for (i in seq(1L, length(rest), by = 2L)) { if (!startsWith(rest[i], '--')) fail('Expected --key, received: ', rest[i]); a[[substring(rest[i], 3L)]] <- rest[i + 1L] }
  allowed <- list(preview = c('input', 'header', 'sep', 'encoding', 'na', 'n-head'), import = c('input', 'analysis', 'header', 'names', 'names-file', 'sep', 'encoding', 'na', 'results-dir', 'approval-ref', 'approved'))
  if (!cmd %in% names(allowed)) fail('Unknown command "', cmd, '". Commands: preview, import')
  bad <- setdiff(names(a), allowed[[cmd]]); if (length(bad)) fail('Unknown option(s) for ', cmd, ': --', paste(bad, collapse = ', --'))
  if (is.null(a$input)) fail('--input is required.')
  tf <- function(v) if (is.null(v)) NULL else if (v %in% c('true', 'false')) v == 'true' else fail('--header must be true or false.')
  if (cmd == 'preview') { r <- di_preview(a$input, tf(a$header), a$sep, a$encoding, a$na, if (is.null(a[['n-head']])) 5L else as.integer(a[['n-head']])); di_print_preview(r); gmm_finish('SUCCESS', 'preview', 'PREVIEW_READ_ONLY', 'Confirm the settings with the user, then run import.'); return(invisible(r)) }
  if (!is.null(a$names) && !is.null(a[['names-file']])) fail('Use --names or --names-file, not both.')
  nm <- if (!is.null(a[['names-file']])) { f <- resolve_path(a[['names-file']]); if (!file.exists(f)) fail('Names file not found: ', f); trimws(readLines(f, warn = FALSE, encoding = 'UTF-8')) } else if (!is.null(a$names)) trimws(strsplit(a$names, ',', fixed = TRUE)[[1]]) else NULL
  h <- tf(a$header); if (is.null(h)) fail('--header is required.')
  r <- di_import(a$input, a$analysis, h, a$sep, a$encoding, a$na, nm, identical(a$approved, 'true'), a[['approval-ref']], if (is.null(a[['results-dir']])) 'results' else a[['results-dir']])
  cat(sprintf('Imported: %d rows x %d columns; %d cell(s) set to missing.\nOutput: %s\nRecord: %s\nNext: confirm the analysis variables, then workflow.R new-run --analysis %s --import-record <record> --columns ... --objective ... --approved true\n', r$n_rows, r$n_columns, r$cells_set_to_missing, r$output, r$record, a$analysis))
  gmm_finish('SUCCESS', 'import', 'IMPORTED', 'Confirm the analysis variables with the user, then run workflow.R new-run.')
  invisible(r)
}
if (sys.nframe() == 0L) tryCatch(di_cli(commandArgs(trailingOnly = TRUE)),
  stage2_pause = function(e) { cat(conditionMessage(e), '\n'); gmm_finish('AWAITING_USER_APPROVAL', 'import', e$code, 'Decide how to declare the listed cells or correct the source file, then rerun import.') },
  error = function(e) gmm_cli_error(e, 'import'))
