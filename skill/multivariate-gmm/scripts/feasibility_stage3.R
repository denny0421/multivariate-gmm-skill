#!/usr/bin/env Rscript
# Stage 3 - Assumptions and feasibility checks for a component-specific FULL-covariance GMM (v1).
# Generic: any CSV of continuous numeric features (normally Stage 2 processed_data.csv).
# Read-only by default. No EM, no likelihood, no BIC, no model estimation here (Stage 4 is not implemented).
# Data are transformed (z-score) ONLY when the user chose --scale zscore AND approved the whole
# Stage 3 specification (--approved true) AND no STOP/PAUSE remains; the input is never modified.
#
# Reuses the tested Stage 2 utilities (paths, staged output commit) by sourcing data_stage2.R
# as a library; Stage 2 behaviour is unchanged.
suppressPackageStartupMessages(library(jsonlite))

stage3_script_path <- function() {
  for (f in rev(sys.frames())) {
    of <- f$ofile
    if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/'))
  }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
STAGE3_SCRIPT_DIR <- dirname(stage3_script_path())
if (is.na(STAGE3_SCRIPT_DIR) || !file.exists(file.path(STAGE3_SCRIPT_DIR, 'data_stage2.R'))) stop('Cannot locate the Skill scripts directory.', call. = FALSE)
source(file.path(STAGE3_SCRIPT_DIR, 'data_stage2.R'), local = TRUE)

STAGE3_VERSION <- '0.1.0'
STAGE3_CONFIG_KEYS <- c('input', 'output', 'columns', 'id-column', 'g', 'scale', 'objective', 'rows-independent', 'independence-note')
STAGE3_CLI_KEYS <- c(STAGE3_CONFIG_KEYS, 'approved', 'config')
STAGE3_COVARIANCE <- 'full, component-specific, unconstrained (mclust "VVV")'
STAGE3_STATUS_ORDER <- c(PASS = 1L, WARNING = 2L, PAUSE = 3L, STOP = 4L)

# Screening thresholds. Exact mathematical conditions are marked 'exact'; the others are project
# heuristics that are NOT validated by simulation yet (review item R07).
STAGE3_THRESHOLDS <- list(
  min_unique_values = list(value = 10L, type = 'heuristic', use = 'fewer unique values -> confirm the variable is continuous (PAUSE)'),
  max_value_share = list(value = 0.20, type = 'heuristic', use = 'one value holding a larger share of rows -> tie/degeneracy WARNING'),
  condition_index_corr = list(value = 30, type = 'heuristic (Belsley condition index)', use = 'sqrt(lambda_max/lambda_min) of the correlation matrix -> WARNING'),
  vif = list(value = 10, type = 'heuristic', use = 'variance inflation factor -> WARNING'),
  abs_r = list(value = 0.90, type = 'heuristic', use = '|Pearson r| -> WARNING'),
  sd_ratio_scale = list(value = 10, type = 'heuristic', use = 'max SD / min SD across features -> z-score is recommended more strongly'),
  cov_condition_numeric = list(value = 1e10, type = 'heuristic (double-precision safety)', use = 'lambda_max/lambda_min of the covariance on the chosen scale -> WARNING'),
  mahalanobis_quantile = list(value = 0.999, type = 'screening', use = 'chi-square(p) quantile for global Mahalanobis D^2 screening -> WARNING'),
  abs_skew = list(value = 2, type = 'heuristic (West, Finch & Curran 1995)', use = 'marginal |skewness| -> WARNING'),
  excess_kurtosis = list(value = 7, type = 'heuristic (West, Finch & Curran 1995)', use = 'marginal excess kurtosis -> WARNING'),
  obs_per_param_per_component = list(value = 5, type = 'heuristic', use = 'n/G below 5 x per-component parameters -> WARNING'),
  min_obs_per_component = list(value = 'p + 1', type = 'exact', use = 'n/G < p+1 guarantees some component has fewer than p+1 points -> singular covariance -> STOP'),
  total_params = list(value = 'k_G < n', type = 'exact (estimability/BIC meaningfulness)', use = 'k_G >= n -> STOP'))

worst_status <- function(s) names(STAGE3_STATUS_ORDER)[max(STAGE3_STATUS_ORDER[s])]

parse_g <- function(g) {
  if (is.numeric(g)) return(as.integer(g))
  g <- gsub('\\s', '', as.character(g))
  parts <- strsplit(g, ',', fixed = TRUE)[[1L]]
  out <- integer()
  for (s in parts) {
    if (grepl('^-?[0-9]+:-?[0-9]+$', s)) { ab <- as.integer(strsplit(s, ':', fixed = TRUE)[[1L]]); out <- c(out, seq(ab[1], ab[2])) }
    else if (grepl('^-?[0-9]+$', s)) out <- c(out, as.integer(s))
    else fail('Invalid --g value "', s, '"; use e.g. 1:5 or 1,2,3.')
  }
  if (!length(out)) fail('No candidate G given.')
  sort(unique(out))
}

k_full <- function(G, p) (G - 1) + G * p + G * p * (p + 1) / 2

hash_object <- function(x) {
  f <- tempfile(fileext = '.json'); on.exit(unlink(f))
  jsonlite::write_json(x, f, auto_unbox = TRUE, digits = NA, null = 'null', na = 'null')
  unname(tools::md5sum(f))
}

stage3_check <- function(id, maps_to, check, status, evidence, rationale, metrics = list()) {
  list(id = id, maps_to = maps_to, check = check, status = status, evidence = evidence, rationale = rationale, metrics = metrics)
}

# ---------------------------------------------------------------------------------------------
feasibility <- function(input, output, columns = NULL, id_column = NULL, g = '1:5', scale = NULL,
                        objective = NULL, rows_independent = NULL, approved = FALSE, config_file = NULL,
                        independence_note = NULL) {
  approved <- isTRUE(approved)
  if (!is.null(scale) && !scale %in% c('zscore', 'none')) fail("--scale must be 'zscore' or 'none'.")
  if (!is.null(objective) && !objective %in% c('clustering', 'density')) fail("--objective must be 'clustering' or 'density'.")
  # TRUE = independence established by the study design; 'assumed' = adopted as a working assumption
  # (Decision tree Q7 UNKNOWN -> WARNING); FALSE = known dependence.
  if (!is.null(rows_independent) && !(isTRUE(rows_independent) || isFALSE(rows_independent) || identical(rows_independent, 'assumed'))) {
    fail("rows_independent must be TRUE, FALSE or 'assumed'.")
  }
  if (identical(rows_independent, 'assumed') && (is.null(independence_note) || !nzchar(trimws(independence_note)))) {
    fail('rows_independent = assumed requires an independence note describing the possible dependence (--independence-note).')
  }
  G <- parse_g(g)

  input_path <- resolve_path(input)
  if (!file.exists(input_path) || dir.exists(input_path)) fail('Input CSV not found: ', input_path)
  output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory (', STAGE2_SKILL_ROOT, '). Use e.g. results/<name>.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  raw <- read.csv(input_path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''), fileEncoding = 'UTF-8-BOM')
  if (nrow(raw) < 1L) fail('Input contains zero rows.')
  if (is.null(id_column) && 'source_row_id' %in% names(raw)) id_column <- 'source_row_id'
  if (!is.null(id_column) && !id_column %in% names(raw)) fail('ID column not found: ', id_column)
  if (is.null(columns)) {
    cols <- setdiff(names(raw)[vapply(raw, is.numeric, logical(1))], id_column)
  } else {
    cols <- if (length(columns) == 1L) trimws(strsplit(columns, ',', fixed = TRUE)[[1L]]) else columns
  }
  if (length(cols) < 2L || anyDuplicated(cols) || any(!cols %in% names(raw))) fail('Provide at least two distinct, existing feature columns.')
  if (!is.null(id_column) && id_column %in% cols) fail('The ID column cannot be a feature.')
  row_id <- if (is.null(id_column)) seq_len(nrow(raw)) else raw[[id_column]]
  if (anyDuplicated(row_id)) fail('Row IDs must be unique.')
  x <- raw[, cols, drop = FALSE]
  n <- nrow(x); p <- length(cols)
  checks <- list()
  add <- function(...) checks[[length(checks) + 1L]] <<- stage3_check(...)

  # ---- S3-01 input integrity -------------------------------------------------------------
  numeric_ok <- vapply(x, is.numeric, logical(1))
  m <- if (all(numeric_ok)) as.matrix(x) else NULL
  na_n <- if (!is.null(m)) sum(is.na(m)) else NA_integer_
  inf_n <- if (!is.null(m)) sum(is.infinite(m)) else NA_integer_
  s01 <- if (!all(numeric_ok)) 'STOP' else if (inf_n > 0L) 'STOP' else if (na_n > 0L) 'PAUSE' else if (n < 2L) 'STOP' else 'PASS'
  add('S3-01', 'C04 / Q4', 'Input integrity: numeric, finite, complete', s01,
      if (!all(numeric_ok)) paste('Non-numeric columns:', paste(cols[!numeric_ok], collapse = ', ')) else
        sprintf('n = %d rows, p = %d features, NA/NaN = %d, Inf = %d', n, p, na_n, inf_n),
      'The v1 likelihood is defined for complete, finite continuous vectors. NA/NaN must be handled in Stage 2 (PAUSE, return to the missing-data menu); Inf is invalid data (STOP until corrected).',
      list(n = n, p = p, na_cells = na_n, inf_cells = inf_n))
  data_ok <- identical(s01, 'PASS')

  var_diag <- NULL; usable <- FALSE
  if (data_ok) {
    sds <- apply(m, 2, sd); means <- colMeans(m)
    n_unique <- apply(m, 2, function(v) length(unique(v)))
    max_share <- apply(m, 2, function(v) max(table(v)) / length(v))
    sk <- apply(m, 2, eda_skew); ku <- apply(m, 2, eda_exkurt)
    z_out <- vapply(seq_len(p), function(j) if (sds[j] > 0) sum(abs((m[, j] - means[j]) / sds[j]) > 3) else NA_integer_, integer(1))
    var_diag <- data.frame(variable = cols, mean = means, sd = sds, min = apply(m, 2, min), max = apply(m, 2, max),
                           n_unique = n_unique, max_value_share = max_share, skewness = sk, excess_kurtosis = ku,
                           n_abs_z_gt3 = z_out, row.names = NULL)

    # ---- S3-02 feature semantics ---------------------------------------------------------
    low <- cols[n_unique < STAGE3_THRESHOLDS$min_unique_values$value]
    add('S3-02', 'C03 / Q3', 'Features plausibly continuous', if (length(low)) 'PAUSE' else 'PASS',
        if (length(low)) paste('Few distinct values:', paste(sprintf('%s (%d)', low, n_unique[low]), collapse = ', ')) else
          sprintf('Distinct values per feature: %s', paste(sprintf('%s=%d', cols, n_unique), collapse = ', ')),
        'Gaussian components assume continuous measurements. Integer codes, Likert items or ordinal scales cannot be confirmed from a CSV alone, so few distinct values requires the user to confirm the semantics (Decision tree Q3 UNKNOWN).',
        list(n_unique = as.list(n_unique)))

    # ---- S3-03 zero variance ---------------------------------------------------------------
    zero <- cols[!(sds > 0)]
    add('S3-03', 'C05 / Q5', 'No zero-variance features', if (length(zero)) 'STOP' else 'PASS',
        if (length(zero)) paste('Zero variance:', paste(zero, collapse = ', ')) else sprintf('Smallest SD = %.4g (%s)', min(sds), cols[which.min(sds)]),
        'A constant feature makes every covariance matrix singular (zero eigenvalue), so the full-covariance Gaussian density is undefined. The variable must be revised.')

    # ---- S3-04 rank -------------------------------------------------------------------------
    mc <- sweep(m, 2, means, '-')
    rk <- qr(mc, tol = 1e-9)$rank
    s04 <- if (n <= p) 'STOP' else if (rk < p) 'STOP' else 'PASS'
    add('S3-04', 'C05 / Q5', 'Full column rank of the centred data matrix', s04,
        sprintf('rank = %d of p = %d; n = %d', rk, p, n),
        'An exact linear dependency (or n <= p) makes the sample covariance singular for every component, so the full-covariance likelihood is unbounded/undefined. Variables must be revised; nothing is dropped automatically.',
        list(rank = rk, n = n, p = p))
    usable <- length(zero) == 0L && identical(s04, 'PASS')
  }

  cov_info <- list(); outl <- NULL; dup_max <- NA_integer_
  if (usable) {
    # ---- S3-05 collinearity -------------------------------------------------------------------
    r <- cor(m)
    ev_r <- eigen(r, symmetric = TRUE, only.values = TRUE)$values
    ci_r <- sqrt(max(ev_r) / min(ev_r))
    vif <- diag(solve(r))
    hp <- which(abs(r) > STAGE3_THRESHOLDS$abs_r$value & upper.tri(r), arr.ind = TRUE)
    s05_flags <- c(if (ci_r > STAGE3_THRESHOLDS$condition_index_corr$value) sprintf('condition index %.1f', ci_r),
                   if (any(vif > STAGE3_THRESHOLDS$vif$value)) paste('VIF >', STAGE3_THRESHOLDS$vif$value, ':', paste(cols[vif > STAGE3_THRESHOLDS$vif$value], collapse = ', ')),
                   if (nrow(hp)) paste('|r| > 0.90:', paste(sprintf('%s~%s', cols[hp[, 1]], cols[hp[, 2]]), collapse = ', ')))
    add('S3-05', 'C05', 'Near-collinearity (correlation scale)', if (length(s05_flags)) 'WARNING' else 'PASS',
        sprintf('Condition index = %.2f; max VIF = %.2f (%s); max |r| = %.3f%s', ci_r, max(vif), cols[which.max(vif)],
                max(abs(r[upper.tri(r)])), if (length(s05_flags)) paste0('; flags: ', paste(s05_flags, collapse = '; ')) else ''),
        'Strong linear dependence carries over to the within-component covariances, which are estimated from fewer rows, making them ill-conditioned and EM updates unstable. High correlation is substantively meaningful and is not by itself a reason to drop a variable.',
        list(condition_index = ci_r, vif = as.list(vif), eigenvalues = ev_r))

    # ---- S3-06 scale decision --------------------------------------------------------------------
    sd_ratio <- max(sds) / min(sds)
    s06 <- if (is.null(scale)) 'PAUSE' else if (scale == 'none' && sd_ratio > 100) 'WARNING' else 'PASS'
    add('S3-06', 'C06 / Q6', 'Scale decision (z-score standardization)', s06,
        sprintf('SD ratio max/min = %.1f (%s / %s); decision: %s', sd_ratio, cols[which.max(sds)], cols[which.min(sds)],
                if (is.null(scale)) 'NOT YET CHOSEN (recommended: zscore)' else scale),
        paste('Recommended default: z-score each feature (mean 0, SD 1) using the Stage 3 input rows.',
              'For an unconstrained full-covariance GMM the maximum-likelihood partition is equivariant to per-variable rescaling, so standardization does not change the model in exact arithmetic;',
              'it improves numerical conditioning, makes distance-based initialisation (k-means / hierarchical) and any future regularisation scale-free, and puts profiles on comparable units.',
              'Original units keep direct interpretability. The data are not transformed until the user chooses and approves.'),
        list(sd_ratio = sd_ratio, decision = scale))

    # ---- S3-07 outliers ------------------------------------------------------------------------------
    S <- cov(m)
    zm <- sweep(mc, 2, sds, '/')
    d2 <- mahalanobis(zm, rep(0, p), r) # identical to D^2 in original units (affine invariant), numerically stable
    cut <- qchisq(STAGE3_THRESHOLDS$mahalanobis_quantile$value, df = p)
    flagged <- which(d2 > cut)
    outl <- data.frame(row_id = row_id, mahalanobis_d2 = d2, p_value_chisq = pchisq(d2, df = p, lower.tail = FALSE),
                       flagged = d2 > cut)
    add('S3-07', 'C07', 'Outlier screening (univariate |z| > 3, global Mahalanobis D^2)', if (length(flagged)) 'WARNING' else 'PASS',
        sprintf('%d row(s) with D^2 > chi2(%d, 0.999) = %.2f%s; univariate |z|>3 counts: %s', length(flagged), p, cut,
                if (length(flagged)) paste0(' (row IDs: ', paste(head(row_id[order(-d2)][seq_along(flagged)], 20), collapse = ', '), ')') else '',
                paste(sprintf('%s=%d', cols, z_out), collapse = ', ')),
        'Isolated extreme points can attract their own small component whose covariance collapses (unbounded likelihood). The global D^2 assumes one Gaussian, so under a mixture it is only a screen: points between or far from groups are flagged, not proven errors. Rows are never deleted automatically.',
        list(n_flagged = length(flagged), cutoff = cut, expected_under_single_gaussian = n * (1 - STAGE3_THRESHOLDS$mahalanobis_quantile$value)))

    # ---- S3-08 ties / duplicates --------------------------------------------------------------------
    key <- apply(m, 1, function(v) paste(format(v, digits = 15), collapse = '|'))
    dup_tab <- table(key); dup_max <- as.integer(max(dup_tab)); n_dup_rows <- sum(dup_tab[dup_tab > 1])
    tie_vars <- cols[max_share > STAGE3_THRESHOLDS$max_value_share$value]
    s08 <- if (dup_max >= p + 1L || length(tie_vars)) 'WARNING' else 'PASS'
    add('S3-08', 'C10', 'Ties and duplicate rows (degenerate-component risk)', s08,
        sprintf('Rows in duplicate groups = %d; largest identical group = %d (p+1 = %d); max single-value share = %.3f (%s)',
                n_dup_rows, dup_max, p + 1L, max(max_share), cols[which.max(max_share)]),
        'p+1 or more identical rows, or a value shared by many rows (rounding/lattice data), let a component sit on those points with a covariance tending to singular, where the likelihood diverges. Duplicates may be valid observations and are not removed.',
        list(largest_duplicate_group = dup_max, rows_in_duplicate_groups = n_dup_rows, tie_heavy_variables = I(tie_vars)))

    # ---- S3-09 global covariance -----------------------------------------------------------------
    # Positive definiteness is scale-free: judge it on the correlation matrix (covariance of z-scores);
    # a Cholesky failure in original units only can be a units/precision artefact (reported, flagged via condition number).
    pd_ok <- !inherits(tryCatch(chol(r), error = function(e) e), 'error')
    pd_raw <- !inherits(tryCatch(chol(S), error = function(e) e), 'error')
    ev_raw <- eigen(S, symmetric = TRUE, only.values = TRUE)$values
    kappa_raw <- max(ev_raw) / min(ev_raw)
    kappa_z <- max(ev_r) / min(ev_r) # covariance of z-scores = correlation matrix
    kappa_used <- if (identical(scale, 'zscore')) kappa_z else kappa_raw
    s09 <- if (!pd_ok) 'STOP' else if (kappa_used > STAGE3_THRESHOLDS$cov_condition_numeric$value || (!identical(scale, 'zscore') && !pd_raw)) 'WARNING' else 'PASS'
    add('S3-09', 'C10', 'Pooled covariance positive definite and numerically conditioned', s09,
        sprintf('Cholesky (correlation scale) %s, (original units) %s; condition number lambda_max/lambda_min: original units = %.3g, z-scores = %.3g',
                if (pd_ok) 'succeeds' else 'FAILS', if (pd_raw) 'succeeds' else 'FAILS', kappa_raw, kappa_z),
        'Each component covariance must be positive definite. If even the pooled covariance is badly conditioned, smaller within-component samples will be worse. A large condition number in original units that disappears after z-scoring reflects unit differences, not redundancy.',
        list(cholesky_ok = pd_ok, cholesky_original_units_ok = pd_raw, condition_original = kappa_raw, condition_zscore = kappa_z))
    cov_info <- list(condition_original = kappa_raw, condition_zscore = kappa_z)

    # ---- S3-10 Gaussian working model --------------------------------------------------------------
    heavy <- cols[abs(sk) > STAGE3_THRESHOLDS$abs_skew$value | ku > STAGE3_THRESHOLDS$excess_kurtosis$value]
    add('S3-10', 'C09 / Q8', 'Gaussian components as a working model (no global normality test)', if (length(heavy)) 'WARNING' else 'PASS',
        sprintf('Marginal skewness: %s; excess kurtosis: %s%s', paste(sprintf('%s=%.2f', cols, sk), collapse = ', '),
                paste(sprintf('%s=%.2f', cols, ku), collapse = ', '), if (length(heavy)) paste0('; strong skew/heavy tails: ', paste(heavy, collapse = ', ')) else ''),
        'A mixture does not require the pooled data to be multivariate normal; multimodality or skewness may be exactly what extra components describe. Only each component is assumed Gaussian, so no global MVN test is applied. Strong marginal skew or heavy tails can, however, be fitted by extra components that do not correspond to groups.',
        list(heavy_tail_or_skewed = I(heavy)))
  }

  # ---- S3-11 candidate G ---------------------------------------------------------------------------
  q_comp <- p + p * (p + 1) / 2
  cand <- do.call(rbind, lapply(G, function(gg) {
    if (gg < 1L || gg > n) {
      return(data.frame(G = gg, k_G = NA_real_, n_per_component = NA_real_, n_over_k = NA_real_,
                        params_per_component = q_comp, status = 'STOP', reason = 'G must satisfy 1 <= G <= n'))
    }
    k <- k_full(gg, p); npc <- n / gg
    st <- 'PASS'; why <- 'feasible to attempt; numerical checks still needed in Stage 4'
    if (k >= n) { st <- 'STOP'; why <- sprintf('k_G = %d >= n = %d: more free parameters than observations', k, n) }
    else if (npc < p + 1) { st <- 'STOP'; why <- sprintf('n/G = %.1f < p+1 = %d: some component must have < p+1 rows, so its covariance is singular', npc, p + 1) }
    else if (npc < STAGE3_THRESHOLDS$obs_per_param_per_component$value * q_comp) {
      st <- 'WARNING'; why <- sprintf('n/G = %.1f < %d x %g per-component parameters = %g: covariance estimates may be unstable, more so for unequal components',
                                      npc, STAGE3_THRESHOLDS$obs_per_param_per_component$value, q_comp, STAGE3_THRESHOLDS$obs_per_param_per_component$value * q_comp)
    }
    data.frame(G = gg, k_G = k, n_per_component = npc, n_over_k = n / k, params_per_component = q_comp, status = st, reason = why)
  }))
  cs <- cand$status
  s11 <- if (all(cs == 'STOP')) 'STOP' else if (any(cs == 'STOP')) 'PAUSE' else if (any(cs == 'WARNING') || !1L %in% G) 'WARNING' else 'PASS'
  add('S3-11', 'C08 / Q9', 'Candidate G and parameter count k_G = (G-1) + G*p + G*p*(p+1)/2', s11,
      paste0(sprintf('G = {%s}; ', paste(G, collapse = ',')), paste(sprintf('G=%d: %s', cand$G, cand$status), collapse = '; '),
             if (!1L %in% G) '; G = 1 not included' else '',
             if (any(cs == 'STOP') && !all(cs == 'STOP')) '; remove STOP candidates (they are not dropped automatically)' else ''),
      paste('The parameter count alone does not prove estimability; what matters is effective rows per component relative to p and to the',
            q_comp, 'mean+covariance parameters each component needs. n/G < p+1 is an exact singularity condition (STOP); the 5x rule is an unvalidated heuristic (WARNING).',
            'G = 1 should be included so that "no multi-component structure preferred" remains a possible conclusion.'),
      list(G = G, params_per_component = q_comp))

  # ---- S3-12 covariance structure ------------------------------------------------------------------
  add('S3-12', 'C10', 'Covariance structure fixed for v1', 'PASS', STAGE3_COVARIANCE,
      'v1 compares only component-specific full covariance models. Other covariance families change the parameter count and would require a separate, approved specification.')

  # ---- S3-13 objective / S3-14 independence ---------------------------------------------------------
  add('S3-13', 'C01 / Q1', 'Analysis objective recorded', if (is.null(objective)) 'PAUSE' else 'PASS',
      if (is.null(objective)) 'Not recorded: clustering or density?' else objective,
      'The objective routes Stage 5/6 reporting: clustering interprets components as candidate groups; density estimation does not require group labels or profiling.')
  s14 <- if (is.null(rows_independent)) 'PAUSE' else if (identical(rows_independent, 'assumed')) 'WARNING' else if (!rows_independent) 'STOP' else 'PASS'
  add('S3-14', 'C02 / Q7', 'Rows are independent observation units', s14,
      paste0(if (is.null(rows_independent)) 'Not confirmed by the user (cannot be determined from the CSV)' else
               if (identical(rows_independent, 'assumed')) 'Adopted by the user as a WORKING ASSUMPTION; not established by the data' else
               if (rows_independent) 'Confirmed by user from the study design' else 'User reports dependence (repeated or clustered units)',
             if (!is.null(independence_note)) paste0('. Note: ', independence_note) else ''),
      'The mixture likelihood multiplies row densities, which assumes independent rows. Independence cannot be proven from the data; a working assumption is a disclosed WARNING (Q7 UNKNOWN). Repeated measures or clustered units need a different model or a redesigned dataset.')

  # ---- S3-15 approval gate ------------------------------------------------------------------------
  pre <- vapply(checks, `[[`, character(1), 'status')
  blocking <- vapply(checks, function(cn) cn$status %in% c('PAUSE', 'STOP'), logical(1))
  approved_for_fit <- approved && !any(blocking)
  s15 <- if (approved_for_fit) 'PASS' else if (any(pre == 'STOP')) 'STOP' else 'PAUSE'
  add('S3-15', 'C11 / Q10', 'User approval of the complete Stage 3 specification', s15,
      if (approved_for_fit) 'Approved (--approved true) with no outstanding decision' else if (approved) 'Approval given but blocked by outstanding PAUSE/STOP items' else 'Not yet approved',
      'Fitting may start only after the user approves the exact specification (data, features, scale, G candidates, covariance). STOP and PAUSE cannot be bypassed by approval.')

  status_vec <- vapply(checks, `[[`, character(1), 'status')
  overall <- worst_status(status_vec)
  outstanding <- vapply(Filter(function(cn) cn$status %in% c('PAUSE', 'STOP') && cn$id != 'S3-15', checks),
                        function(cn) sprintf('%s %s [%s]: %s', cn$id, cn$check, cn$status, cn$evidence), character(1))

  # ---- specification & transform ------------------------------------------------------------------
  transform <- NULL
  if (identical(scale, 'zscore') && usable) transform <- data.frame(variable = cols, center = colMeans(m), scale = apply(m, 2, sd), row.names = NULL)
  spec <- list(spec_version = 'stage3-v1', input = list(path = input_path, md5 = unname(tools::md5sum(input_path)), n_rows = n),
               id_column = if (is.null(id_column)) '(row number)' else id_column, row_ids_md5 = hash_object(as.character(row_id)),
               features = I(cols), objective = objective,
               rows_independent = if (identical(rows_independent, 'assumed')) 'working assumption' else rows_independent,
               independence_note = independence_note,
               outlier_policy = 'flag only; no rows removed by Stage 3',
               scale = list(method = if (is.null(scale)) 'undecided' else scale,
                            parameters = if (is.null(transform)) NULL else list(center = as.list(setNames(transform$center, cols)),
                                                                                scale = as.list(setNames(transform$scale, cols)))),
               G_candidates = I(G), covariance = STAGE3_COVARIANCE,
               stage4_numerical_settings = 'not specified (Stage 4 not implemented)')
  spec_hash <- hash_object(spec)
  approval_id <- if (approved_for_fit) paste0('S3-', format(Sys.time(), '%Y%m%dT%H%M%S', tz = 'UTC'), '-', substr(spec_hash, 1, 8)) else NULL
  result <- list(stage = 3, script_version = STAGE3_VERSION, generated_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
                 status = overall, approved_for_fit = approved_for_fit, approval_id = approval_id, spec_hash = spec_hash,
                 n = n, p = p, features = I(cols), G_candidates = I(G), covariance = STAGE3_COVARIANCE,
                 outstanding_decisions = I(outstanding),
                 scale_decision = if (is.null(scale)) 'undecided' else scale, objective = objective,
                 rows_independent = spec$rows_independent, independence_note = independence_note,
                 outlier_policy = spec$outlier_policy,
                 data_transformed = approved_for_fit && !is.null(transform),
                 next_action = if (approved_for_fit) 'STAGE4_NOT_IMPLEMENTED' else if (overall == 'STOP') 'REVISE_DATA_OR_SPEC' else 'USER_DECISIONS_REQUIRED',
                 gmm_fitted = FALSE, global_normality_required = FALSE, checks = checks, thresholds = STAGE3_THRESHOLDS,
                 output_dir = output_path)
  run_config <- list(script_version = STAGE3_VERSION, input = input_path, output = output_path, columns = I(cols),
                     id_column = id_column, g = I(G), scale = scale, objective = objective, rows_independent = rows_independent,
                     independence_note = independence_note,
                     approved = approved, config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL)

  checks_df <- do.call(rbind, lapply(checks, function(cn) data.frame(id = cn$id, maps_to = cn$maps_to, check = cn$check,
                                                                    status = cn$status, evidence = cn$evidence, rationale = cn$rationale)))
  required <- c('stage3_checks.json', 'stage3_checks.csv', 'candidate_feasibility.csv', 'stage3_report.md', 'stage3_spec.json', 'run_config.json')
  if (!is.null(var_diag)) required <- c(required, 'variable_diagnostics.csv')
  if (!is.null(outl)) required <- c(required, 'outlier_screening.csv')
  if (result$data_transformed) required <- c(required, 'transformed_data.csv', 'transform_params.csv')

  writer <- function(dir) {
    write_json_file(result, file.path(dir, 'stage3_checks.json'))
    write.csv(checks_df, file.path(dir, 'stage3_checks.csv'), row.names = FALSE)
    write.csv(cand, file.path(dir, 'candidate_feasibility.csv'), row.names = FALSE)
    if (!is.null(var_diag)) write.csv(var_diag, file.path(dir, 'variable_diagnostics.csv'), row.names = FALSE)
    if (!is.null(outl)) write.csv(outl[order(-outl$mahalanobis_d2), ], file.path(dir, 'outlier_screening.csv'), row.names = FALSE)
    write_json_file(c(spec, list(spec_hash = spec_hash, approved_for_fit = approved_for_fit, approval_id = approval_id)),
                    file.path(dir, 'stage3_spec.json'))
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    if (result$data_transformed) {
      z <- sweep(sweep(m, 2, transform$center, '-'), 2, transform$scale, '/')
      write.csv(setNames(data.frame(row_id, z, check.names = FALSE), c(if (is.null(id_column)) 'row_id' else id_column, cols)),
                file.path(dir, 'transformed_data.csv'), row.names = FALSE)
      write.csv(transform, file.path(dir, 'transform_params.csv'), row.names = FALSE)
    }
    writeLines(stage3_report_md(result, checks_df, cand, var_diag, outl, scale), file.path(dir, 'stage3_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) {
    f <- file.path(dir, required)
    bad <- required[!file.exists(f) | file.size(f) <= 0]
    if (length(bad)) fail('Staged Stage 3 output incomplete: ', paste(bad, collapse = ', '))
    if (!identical(jsonlite::fromJSON(file.path(dir, 'stage3_checks.json'))$status, overall)) fail('stage3_checks.json failed validation.')
    if (result$data_transformed) {
      t <- read.csv(file.path(dir, 'transformed_data.csv'), check.names = FALSE)
      if (nrow(t) != n || any(abs(colMeans(t[, cols])) > 1e-8) || any(abs(apply(t[, cols], 2, sd) - 1) > 1e-8)) fail('transformed_data.csv failed validation.')
    }
  }
  stage_and_commit(output_path, writer, validator)
  invisible(result)
}

# ---------------------------------------------------------------------------------------------
md_escape <- function(s) gsub('|', '\\|', s, fixed = TRUE)
stage3_report_md <- function(res, checks_df, cand, var_diag, outl, scale) {
  f <- function(x, d = 3) formatC(x, format = 'g', digits = d)
  L <- c('# Stage 3 - Assumptions and feasibility report', '',
         sprintf('- **Overall status: %s**   (approved for fit: %s)', res$status, if (res$approved_for_fit) 'yes' else 'no'),
         sprintf('- Data: n = %d rows, p = %d features (%s)', res$n, res$p, paste(res$features, collapse = ', ')),
         sprintf('- Candidate G: %s; covariance: %s', paste(res$G_candidates, collapse = ', '), res$covariance),
         sprintf('- Spec hash: `%s`%s', res$spec_hash, if (!is.null(res$approval_id)) sprintf('; approval ID: `%s`', res$approval_id) else ''),
         sprintf('- Decisions: scale = %s; objective = %s; independent rows = %s', res$scale_decision,
                 if (is.null(res$objective)) 'undecided' else res$objective,
                 if (is.null(res$rows_independent)) 'undecided' else as.character(res$rows_independent)),
         if (!is.null(res$independence_note)) paste0('- Independence limitation: ', md_escape(res$independence_note)),
         sprintf('- Outlier policy: %s', res$outlier_policy),
         '- No GMM, EM, likelihood or BIC was computed (Stage 4 is not implemented). A global multivariate-normality test is deliberately **not** required.',
         '', '## Outstanding decisions / blocking items', '')
  L <- c(L, if (length(res$outstanding_decisions)) paste('-', md_escape(res$outstanding_decisions)) else '- None.')
  if (is.null(scale)) {
    L <- c(L, '', '## Scale choice (user decision required)', '',
           '| Option | Effect |', '|---|---|',
           '| **A. Z-score standardization (recommended default)** | Each feature centred and divided by its SD from these rows; parameters saved in `transform_params.csv` for back-transformation. Better numerical conditioning and scale-free initialisation. |',
           '| B. Keep original units | Direct interpretability; for an unconstrained full-covariance GMM the ML partition is the same in exact arithmetic, but conditioning and distance-based initialisation depend on units. |',
           '', 'Nothing is transformed until the user chooses and approves the full specification (`--scale zscore|none --approved true`).')
  }
  L <- c(L, '', '## Checks', '', '| ID | Maps to | Check | Status | Evidence |', '|---|---|---|---|---|',
         sprintf('| %s | %s | %s | **%s** | %s |', checks_df$id, checks_df$maps_to, md_escape(checks_df$check), checks_df$status, md_escape(checks_df$evidence)))
  L <- c(L, '', '## Candidate G feasibility', '', '| G | k_G | n/G | n/k_G | Status | Reason |', '|---|---|---|---|---|---|',
         sprintf('| %d | %s | %s | %s | %s | %s |', cand$G, f(cand$k_G, 4), f(cand$n_per_component, 4), f(cand$n_over_k, 3), cand$status, md_escape(cand$reason)))
  if (!is.null(var_diag)) {
    L <- c(L, '', '## Feature diagnostics', '', '| Feature | Mean | SD | Unique | Max value share | Skew | Excess kurtosis | abs(z)>3 |', '|---|---|---|---|---|---|---|---|',
           sprintf('| %s | %s | %s | %d | %.3f | %.2f | %.2f | %s |', var_diag$variable, f(var_diag$mean, 5), f(var_diag$sd, 4), var_diag$n_unique,
                   var_diag$max_value_share, var_diag$skewness, var_diag$excess_kurtosis, var_diag$n_abs_z_gt3))
  }
  if (!is.null(outl)) {
    top <- head(outl[order(-outl$mahalanobis_d2), ], 10)
    L <- c(L, '', '## Largest global Mahalanobis distances (screening only)', '', '| Row ID | D^2 | p (chi-square) | Flagged |', '|---|---|---|---|',
           sprintf('| %s | %.2f | %.2g | %s |', top$row_id, top$mahalanobis_d2, top$p_value_chisq, ifelse(top$flagged, 'yes', 'no')))
  }
  L <- c(L, '', '## Decision rules and statistical rationale', '', '| ID | Rationale |', '|---|---|',
         sprintf('| %s | %s |', checks_df$id, md_escape(checks_df$rationale)),
         '', 'Status meaning: PASS = adequate; WARNING = may proceed with the caveat disclosed and approved; PAUSE = a user decision is required; STOP = the requested configuration cannot be estimated as specified. PAUSE/STOP cannot be bypassed.',
         'Thresholds marked heuristic in `stage3_checks.json` are project screening choices, not textbook rules, and are not yet simulation-calibrated.')
  enc2utf8(L)
}

# ---------------------------------------------------------------------------------------------
stage3_cli <- function(argv) {
  if (length(argv) %% 2L != 0L) fail('Arguments must use --key value pairs.')
  args <- list()
  for (i in seq(1L, length(argv), by = 2L)) {
    key <- argv[i]; if (!startsWith(key, '--')) fail('Expected --key, received: ', key)
    key <- substring(key, 3L)
    if (!key %in% STAGE3_CLI_KEYS) fail('Unknown argument --', key, '. Allowed: --', paste(STAGE3_CLI_KEYS, collapse = ', --'))
    args[[key]] <- argv[i + 1L]
  }
  if (!is.null(args$config)) {
    path <- resolve_path(args$config)
    if (!file.exists(path)) fail('Config file not found: ', path)
    cfg <- tryCatch(jsonlite::fromJSON(path), error = function(e) fail('Config is not valid JSON: ', conditionMessage(e)))
    names(cfg) <- gsub('_', '-', names(cfg))
    if ('approved' %in% names(cfg)) fail('"approved" is not allowed in a config file; pass --approved true on the command line after the user approves.')
    bad <- setdiff(names(cfg), STAGE3_CONFIG_KEYS)
    if (length(bad)) fail('Unknown config key(s): ', paste(bad, collapse = ', '))
    for (key in names(cfg)) if (is.null(args[[key]])) {
      v <- cfg[[key]]; args[[key]] <- if (is.logical(v)) tolower(as.character(v)) else paste(as.character(v), collapse = ',')
    }
  }
  miss <- setdiff(c('input', 'output'), names(args))
  if (length(miss)) fail('Missing settings (CLI or config): ', paste(miss, collapse = ', '))
  tf <- function(v, name) { if (is.null(v)) return(NULL); if (!v %in% c('true', 'false')) fail('--', name, ' must be true or false.'); v == 'true' }
  ri <- args[['rows-independent']]
  if (!is.null(ri)) {
    if (!ri %in% c('true', 'false', 'assumed')) fail('--rows-independent must be true, false or assumed.')
    ri <- if (ri == 'assumed') 'assumed' else ri == 'true'
  }
  feasibility(args$input, args$output, columns = args$columns, id_column = args[['id-column']],
              g = if (is.null(args$g)) '1:5' else args$g, scale = args$scale, objective = args$objective,
              rows_independent = ri, independence_note = args[['independence-note']],
              approved = isTRUE(tf(args$approved, 'approved')), config_file = args$config)
}

if (sys.nframe() == 0L) {
  res <- tryCatch(stage3_cli(commandArgs(trailingOnly = TRUE)), error = function(e) gmm_cli_error(e, 'stage3'))
  cat('Stage 3 status:', res$status, '\n')
  cat('Approved for fit:', res$approved_for_fit, '\n')
  for (cn in res$checks) cat(sprintf('  %-6s %-8s %s\n', cn$id, cn$status, cn$check))
  if (length(res$outstanding_decisions)) cat('Outstanding:\n', paste0('  - ', res$outstanding_decisions, '\n'), sep = '')
  cat('Output directory:', res$output_dir, '\n')
  if (identical(res$status, 'STOP')) gmm_finish('BLOCKED', 'stage3', 'STAGE3_STOP', 'Revise the data, variables or candidate G listed under Outstanding; approval cannot bypass a STOP.')
  if (identical(res$status, 'PAUSE')) gmm_finish('AWAITING_USER_APPROVAL', 'stage3', 'STAGE3_DECISIONS_REQUIRED', 'Resolve the items under Outstanding, then rerun into a new directory with --approved true after the user approves.')
  gmm_finish('SUCCESS', 'stage3', if (isTRUE(res$approved_for_fit)) 'APPROVED_FOR_FIT' else res$status, 'Stage 4 model fitting.')
}
