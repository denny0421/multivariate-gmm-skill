#!/usr/bin/env Rscript
# Stage 4A-4B: EM for a component-specific FULL-covariance Gaussian mixture (mclust "VVV"), implemented in base R.
# Formulas: references/stage4-em-math.md. No covariance regularisation. No BIC/AIC or model selection here
# (Stage 4D is not implemented); outputs are per-G fits only.
# Generic: works on any complete numeric matrix. The CLI requires an approved Stage 3 specification.
suppressPackageStartupMessages(library(jsonlite))

EM_VERSION <- '0.2.0'
EM_STATUSES <- c('CONVERGED_VALID', 'NOT_CONVERGED', 'DEGENERATE', 'NUMERIC_ERROR', 'INVALID_START')
EM_DEFAULTS <- list(n_starts = 20L, seed = 421L, tol = 1e-6, max_iter = 1000L, init = 'kmeans',
                    max_cov_condition = 1e10, ll_noise_rel = 1e-10, ll_error_rel = 1e-6)
# What each initialisation does. Every method only produces responsibilities; the initial pi, mu and Sigma always come from one em_mstep.
EM_INIT_SPECS <- list(
  kmeans = list(method = 'kmeans', responsibilities = 'hard partition', algorithm = 'stats::kmeans, default Hartigan-Wong, iter.max 100, nstart 1', uses_seed = TRUE),
  random = list(method = 'random', responsibilities = 'hard partition', algorithm = 'balanced partition rep_len(1:G, n), shuffled with sample()', uses_seed = TRUE),
  `random-soft` = list(method = 'random-soft', responsibilities = 'soft', algorithm = 'each row ~ Dirichlet(1,...,1), from independent Gamma(1, 1) draws normalised by row', adjustable_parameters = 'none', status = 'project heuristic, PENDING REVIEW', uses_seed = TRUE),
  ward = list(method = 'ward', responsibilities = 'hard partition', algorithm = 'stats::hclust then cutree', linkage = 'ward.D2', distance = 'euclidean, on the approved analysis matrix', row_order = 'as in the approved analysis matrix', ties = 'resolved by hclust from the row order; no jitter and no row shuffling, so a different row order can give a different partition', uses_seed = FALSE, required_n_starts = 1L))
EM_INIT_METHODS <- names(EM_INIT_SPECS)
EM_RANDOM_INITS <- c('random', 'random-soft')
em_init_spec <- function(method) { if (!method %in% EM_INIT_METHODS) stop('Unknown init method: ', method, call. = FALSE); EM_INIT_SPECS[[method]] }
em_init_detail <- function(method) { s <- em_init_spec(method); s$method <- NULL; paste(sprintf('%s: %s', names(s), vapply(s, as.character, '')), collapse = '; ') }
em_rng_kind <- function() paste(RNGkind(), collapse = '/')
em_check_init <- function(init, n_starts) {
  em_init_spec(init)
  if (identical(init, 'ward') && n_starts != 1) stop(sprintf('init = ward is deterministic and needs n_starts = 1 (received %s): repeating it would count one partition as several starts.', format(n_starts)), call. = FALSE)
  invisible(TRUE)
}

# ---------------------------------------------------------------- core numerics
# log phi_p(x_j; mu, Sigma) for all rows via Cholesky; NULL if Sigma is not positive definite.
em_logdens <- function(X, mu, Sigma) {
  R <- tryCatch(chol(Sigma), error = function(e) NULL)
  if (is.null(R)) return(NULL)
  p <- ncol(X)
  z <- backsolve(R, t(X) - mu, transpose = TRUE) # R^{-T}(x - mu), p x n
  -0.5 * p * log(2 * pi) - sum(log(diag(R))) - 0.5 * colSums(z^2)
}

# E-step: responsibilities and observed-data log-likelihood with log-sum-exp.
em_estep <- function(X, par) {
  G <- length(par$pi); n <- nrow(X)
  a <- matrix(NA_real_, n, G)
  for (i in seq_len(G)) {
    ld <- em_logdens(X, par$mu[i, ], par$Sigma[[i]])
    if (is.null(ld)) return(list(ok = FALSE, reason = sprintf('covariance %d not positive definite in E-step', i)))
    a[, i] <- log(par$pi[i]) + ld
  }
  m <- apply(a, 1, max)
  lse <- m + log(rowSums(exp(a - m)))
  if (any(!is.finite(lse))) return(list(ok = FALSE, reason = 'non-finite log-likelihood contribution'))
  list(ok = TRUE, tau = exp(a - lse), loglik = sum(lse), row_loglik = lse)
}

# M-step: closed-form maximisers of Q (MLE divisor N_i, updated means).
em_mstep <- function(X, tau) {
  n <- nrow(X); p <- ncol(X); G <- ncol(tau)
  Nk <- colSums(tau)
  mu <- matrix(NA_real_, G, p, dimnames = list(NULL, colnames(X)))
  Sigma <- vector('list', G)
  for (i in seq_len(G)) {
    if (!(Nk[i] > 0)) { mu[i, ] <- NA_real_; Sigma[[i]] <- matrix(NA_real_, p, p); next }
    mu[i, ] <- colSums(tau[, i] * X) / Nk[i]
    D <- sweep(X, 2, mu[i, ], '-') * sqrt(tau[, i])
    S <- crossprod(D) / Nk[i]
    Sigma[[i]] <- (S + t(S)) / 2
    dimnames(Sigma[[i]]) <- list(colnames(X), colnames(X))
  }
  list(pi = Nk / n, mu = mu, Sigma = Sigma, Nk = Nk)
}

# Validity of an updated parameter set. Returns NULL when valid, else list(status, reason).
em_check <- function(par, p, min_effective_n, max_cov_condition) {
  if (any(!is.finite(par$Nk)) || any(!is.finite(par$pi))) return(list(status = 'NUMERIC_ERROR', reason = 'non-finite mixing proportion'))
  small <- which(par$Nk < min_effective_n | par$pi <= 0) # checked first: an empty component also has undefined mean/covariance
  if (length(small)) {
    return(list(status = 'DEGENERATE', reason = sprintf('empty/tiny component %s: effective n = %s < %g',
      paste(small, collapse = ','), paste(formatC(par$Nk[small], digits = 3, format = 'g'), collapse = ','), min_effective_n)))
  }
  if (any(!is.finite(par$mu)) || any(!vapply(par$Sigma, function(S) all(is.finite(S)), logical(1)))) {
    return(list(status = 'NUMERIC_ERROR', reason = 'non-finite mean or covariance after M-step'))
  }
  for (i in seq_along(par$Sigma)) {
    if (is.null(tryCatch(chol(par$Sigma[[i]]), error = function(e) NULL))) {
      return(list(status = 'DEGENERATE', reason = sprintf('covariance %d not positive definite', i)))
    }
    ev <- eigen(par$Sigma[[i]], symmetric = TRUE, only.values = TRUE)$values
    kappa <- max(ev) / min(ev)
    if (!is.finite(kappa) || kappa > max_cov_condition) {
      return(list(status = 'DEGENERATE', reason = sprintf('covariance collapse in component %d: condition number %.3g > %.3g', i, kappa, max_cov_condition)))
    }
  }
  NULL
}

# Classify a log-likelihood change (relative to 1 + |previous|).
em_ll_change <- function(old, new, noise_rel = EM_DEFAULTS$ll_noise_rel, error_rel = EM_DEFAULTS$ll_error_rel) {
  rel <- (new - old) / (1 + abs(old))
  list(rel = rel, decrease = rel < 0, flagged = rel < -noise_rel, error = rel < -error_rel)
}

em_cov_conditions <- function(par) vapply(par$Sigma, function(S) { ev <- eigen(S, TRUE, only.values = TRUE)$values; max(ev) / min(ev) }, numeric(1))
em_cov_min_eigen <- function(par) vapply(par$Sigma, function(S) min(eigen(S, TRUE, only.values = TRUE)$values), numeric(1))

# One EM run from an initial parameter set.
em_run <- function(X, par, tol, max_iter, min_effective_n, max_cov_condition) {
  p <- ncol(X)
  out <- function(status, reason, par, e, hist, it, ndec, nflag, maxdec) {
    list(status = status, reason = reason, par = par, tau = if (!is.null(e)) e$tau else NULL,
         loglik = if (length(hist)) hist[length(hist)] else NA_real_, history = hist, iterations = it,
         n_ll_decreases = ndec, n_ll_decreases_flagged = nflag, max_ll_decrease_rel = maxdec)
  }
  chk <- em_check(par, p, min_effective_n, max_cov_condition)
  if (!is.null(chk)) return(out('INVALID_START', paste('initial parameters:', chk$reason), par, NULL, numeric(), 0L, 0L, 0L, 0))
  e <- em_estep(X, par)
  if (!e$ok) return(out('INVALID_START', paste('initial E-step:', e$reason), par, NULL, numeric(), 0L, 0L, 0L, 0))
  hist <- e$loglik; ndec <- 0L; nflag <- 0L; maxdec <- 0
  for (t in seq_len(max_iter)) {
    new_par <- em_mstep(X, e$tau)
    chk <- em_check(new_par, p, min_effective_n, max_cov_condition)
    if (!is.null(chk)) return(out(chk$status, sprintf('iteration %d: %s', t, chk$reason), new_par, NULL, hist, t, ndec, nflag, maxdec))
    e_new <- em_estep(X, new_par)
    if (!e_new$ok) return(out('NUMERIC_ERROR', sprintf('iteration %d: %s', t, e_new$reason), new_par, NULL, hist, t, ndec, nflag, maxdec))
    ch <- em_ll_change(hist[length(hist)], e_new$loglik)
    hist <- c(hist, e_new$loglik)
    if (ch$decrease) { ndec <- ndec + 1L; maxdec <- max(maxdec, -ch$rel) }
    if (ch$flagged) nflag <- nflag + 1L
    if (ch$error) {
      return(out('NUMERIC_ERROR', sprintf('iteration %d: log-likelihood decreased by %.3g (relative) - EM must be non-decreasing', t, -ch$rel),
                 new_par, e_new, hist, t, ndec, nflag, maxdec))
    }
    par <- new_par; e <- e_new
    if (abs(ch$rel) < tol) return(out('CONVERGED_VALID', sprintf('relative change %.3g < tol %.0e', abs(ch$rel), tol), par, e, hist, t, ndec, nflag, maxdec))
  }
  out('NOT_CONVERGED', sprintf('max_iter = %d reached without meeting tol = %.0e', max_iter, tol), par, e, hist, max_iter, ndec, nflag, maxdec)
}

# Dirichlet(1,...,1) responsibilities: an n x G matrix whose rows are non-negative and sum to one.
em_init_soft_tau <- function(n, G) { t <- matrix(stats::rgamma(n * G, 1), n, G); t / rowSums(t) }

# Deterministic Ward partition (see EM_INIT_SPECS$ward for the distance, linkage, row order and ties).
em_init_ward_cl <- function(X, G) stats::cutree(stats::hclust(stats::dist(X, method = 'euclidean'), method = 'ward.D2'), k = G)

# Initial parameters from a partition (k-means, random, Ward) or from soft responsibilities (random-soft).
# Returns list(par) or list(status, reason). Random-soft has no partition to size-check: its small or singular components are caught by em_check in em_run.
em_init <- function(X, G, method, min_effective_n) {
  n <- nrow(X)
  if (method == 'random-soft') {
    tau <- em_init_soft_tau(n, G)
    if (any(!is.finite(tau)) || any(tau < 0) || any(abs(rowSums(tau) - 1) > 1e-12)) return(list(status = 'INVALID_START', reason = 'random-soft responsibilities are not valid probabilities'))
    return(list(par = em_mstep(X, tau)))
  }
  cl <- if (method == 'kmeans') {
    km <- tryCatch(suppressWarnings(stats::kmeans(X, centers = G, iter.max = 100L, nstart = 1L)), error = function(e) NULL)
    if (is.null(km)) return(list(status = 'INVALID_START', reason = 'k-means initialisation failed'))
    km$cluster
  } else if (method == 'random') {
    sample(rep_len(seq_len(G), n))
  } else if (method == 'ward') {
    w <- tryCatch(em_init_ward_cl(X, G), error = function(e) e)
    if (inherits(w, 'error')) return(list(status = 'INVALID_START', reason = paste('Ward initialisation failed:', conditionMessage(w))))
    w
  } else stop('Unknown init method: ', method, call. = FALSE)
  sizes <- tabulate(cl, G)
  if (any(sizes < min_effective_n)) {
    return(list(status = 'INVALID_START', reason = sprintf('initial partition sizes (%s) include a component with < %g rows',
                                                            paste(sizes, collapse = ','), min_effective_n)))
  }
  tau <- matrix(0, n, G); tau[cbind(seq_len(n), cl)] <- 1
  list(par = em_mstep(X, tau))
}

# Canonical component order for reporting: decreasing pi, ties by first mean coordinate.
em_reorder <- function(par, tau) {
  o <- order(-par$pi, par$mu[, 1])
  list(par = list(pi = par$pi[o], mu = par$mu[o, , drop = FALSE], Sigma = par$Sigma[o], Nk = par$Nk[o]),
       tau = tau[, o, drop = FALSE])
}

with_seed <- function(seed, expr) {
  had <- exists('.Random.seed', envir = globalenv(), inherits = FALSE)
  old <- if (had) get('.Random.seed', envir = globalenv()) else NULL
  on.exit(if (had) assign('.Random.seed', old, envir = globalenv()) else if (exists('.Random.seed', envir = globalenv(), inherits = FALSE)) rm('.Random.seed', envir = globalenv()))
  set.seed(seed)
  force(expr)
}

# Fit one G with multiple starts.
em_fit_gmm <- function(X, G, n_starts = EM_DEFAULTS$n_starts, seed = EM_DEFAULTS$seed, tol = EM_DEFAULTS$tol,
                       max_iter = EM_DEFAULTS$max_iter, init = EM_DEFAULTS$init, min_effective_n = NULL,
                       max_cov_condition = EM_DEFAULTS$max_cov_condition) {
  X <- as.matrix(X); storage.mode(X) <- 'double'
  if (is.null(colnames(X))) colnames(X) <- paste0('x', seq_len(ncol(X)))
  n <- nrow(X); p <- ncol(X)
  if (any(!is.finite(X))) stop('X must be complete and finite (handle NA/NaN/Inf in Stage 2).', call. = FALSE)
  if (length(G) != 1L || G < 1 || G != round(G) || G > n) stop('G must be an integer in 1..n.', call. = FALSE)
  if (n_starts < 1 || max_iter < 1 || tol <= 0) stop('n_starts, max_iter and tol must be positive.', call. = FALSE)
  em_check_init(init, n_starts)
  if (is.null(min_effective_n)) min_effective_n <- p + 1
  runs <- list()
  if (G == 1L) {
    par <- em_mstep(X, matrix(1, n, 1))
    chk <- em_check(par, p, min_effective_n, max_cov_condition)
    e <- if (is.null(chk)) em_estep(X, par) else NULL
    runs[[1]] <- if (!is.null(chk)) list(status = chk$status, reason = paste('closed-form MLE:', chk$reason), par = par, tau = NULL,
                                         loglik = NA_real_, history = numeric(), iterations = 0L, n_ll_decreases = 0L,
                                         n_ll_decreases_flagged = 0L, max_ll_decrease_rel = 0, seed = NA_integer_)
                 else list(status = 'CONVERGED_VALID', reason = 'closed-form single-Gaussian MLE', par = par, tau = e$tau,
                           loglik = e$loglik, history = e$loglik, iterations = 1L, n_ll_decreases = 0L,
                           n_ll_decreases_flagged = 0L, max_ll_decrease_rel = 0, seed = NA_integer_)
  } else {
    for (s in seq_len(n_starts)) {
      sd_s <- as.integer(seed + s - 1L)
      r <- with_seed(sd_s, {
        ini <- em_init(X, G, init, min_effective_n)
        if (is.null(ini$par)) list(status = ini$status, reason = ini$reason, par = NULL, tau = NULL, loglik = NA_real_, history = numeric(),
                                   iterations = 0L, n_ll_decreases = 0L, n_ll_decreases_flagged = 0L, max_ll_decrease_rel = 0)
        else em_run(X, ini$par, tol, max_iter, min_effective_n, max_cov_condition)
      })
      r$seed <- sd_s
      runs[[s]] <- r
    }
  }
  valid <- which(vapply(runs, function(r) r$status == 'CONVERGED_VALID', logical(1)))
  lls <- vapply(runs, function(r) r$loglik, numeric(1))
  starts <- data.frame(G = G, start = seq_along(runs), seed = vapply(runs, function(r) r$seed, integer(1)),
    status = vapply(runs, `[[`, character(1), 'status'), iterations = vapply(runs, function(r) as.integer(r$iterations), integer(1)),
    loglik = ifelse(vapply(runs, function(r) r$status, character(1)) %in% c('CONVERGED_VALID', 'NOT_CONVERGED'), lls, NA_real_),
    min_effective_n = vapply(runs, function(r) if (is.null(r$par)) NA_real_ else min(r$par$Nk), numeric(1)),
    min_pi = vapply(runs, function(r) if (is.null(r$par)) NA_real_ else min(r$par$pi), numeric(1)),
    max_cov_condition = vapply(runs, function(r) if (is.null(r$par) || r$status %in% c('NUMERIC_ERROR')) NA_real_ else
                                 tryCatch(max(em_cov_conditions(r$par)), error = function(e) NA_real_), numeric(1)),
    n_ll_decreases = vapply(runs, function(r) as.integer(r$n_ll_decreases), integer(1)),
    n_ll_decreases_flagged = vapply(runs, function(r) as.integer(r$n_ll_decreases_flagged), integer(1)),
    max_ll_decrease_rel = vapply(runs, function(r) r$max_ll_decrease_rel, numeric(1)),
    reason = vapply(runs, `[[`, character(1), 'reason'),
    init_method = if (G == 1L) 'closed_form' else init,
    init_detail = if (G == 1L) 'no initialisation: single-Gaussian MLE' else em_init_detail(init),
    rng_kind = if (G == 1L) NA_character_ else em_rng_kind(),
    min_cov_eigenvalue = vapply(runs, function(r) if (is.null(r$par) || r$status %in% c('NUMERIC_ERROR')) NA_real_ else
                                  tryCatch(min(em_cov_min_eigen(r$par)), error = function(e) NA_real_), numeric(1)),
    stringsAsFactors = FALSE)
  best <- NULL; summary <- list(G = G, n_starts = length(runs), n_valid = length(valid))
  if (length(valid)) {
    b <- valid[which.max(lls[valid])]
    ro <- em_reorder(runs[[b]]$par, runs[[b]]$tau)
    best <- list(start = b, seed = runs[[b]]$seed, loglik = lls[b], iterations = runs[[b]]$iterations, par = ro$par, tau = ro$tau,
                 history = runs[[b]]$history)
    reach <- abs(lls[valid] - lls[b]) / (1 + abs(lls[b])) < 1e-6
    vals <- sort(lls[valid], decreasing = TRUE); distinct <- 1L
    if (length(vals) > 1) for (k in 2:length(vals)) if (abs(vals[k] - vals[k - 1]) / (1 + abs(vals[k - 1])) >= 1e-6) distinct <- distinct + 1L
    summary <- c(summary, list(best_start = b, best_seed = runs[[b]]$seed, best_loglik = lls[b], n_reaching_best = sum(reach),
                               n_distinct_optima = distinct, k_G = (G - 1) + G * p + G * p * (p + 1) / 2))
  }
  summary$status_counts <- as.list(table(factor(starts$status, levels = EM_STATUSES)))
  summary$any_ll_decrease_flagged <- any(starts$n_ll_decreases_flagged > 0)
  list(G = G, best = best, starts = starts, histories = lapply(runs, `[[`, 'history'), summary = summary,
       start_params = lapply(runs, `[[`, 'par'), # final parameters of each start (raw component order), for 4C optimum comparison
       settings = list(n_starts = if (G == 1L) 1L else as.integer(n_starts), seed = seed, tol = tol, max_iter = max_iter, init = init,
                       min_effective_n = min_effective_n, max_cov_condition = max_cov_condition, regularization = 'none',
                       convergence_rule = '|l_t - l_{t-1}| / (1 + |l_{t-1}|) < tol after a full M+E step'))
}

em_fit <- function(X, Gs, ...) setNames(lapply(Gs, function(g) em_fit_gmm(X, g, ...)), paste0('G', Gs))

# Independent mixture log-likelihood (no Cholesky; solve/determinant) for verification.
em_loglik_reference <- function(X, par) {
  X <- as.matrix(X); p <- ncol(X)
  dens <- sapply(seq_along(par$pi), function(i) {
    S <- par$Sigma[[i]]; D <- sweep(X, 2, par$mu[i, ], '-')
    par$pi[i] * exp(-0.5 * rowSums((D %*% solve(S)) * D)) / sqrt((2 * pi)^p * det(S))
  })
  sum(log(rowSums(matrix(dens, nrow(X)))))
}

# ---------------------------------------------------------------- CLI with approved Stage 3 spec
em_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
EM_SCRIPT_DIR <- dirname(em_script_path())
if (!is.na(EM_SCRIPT_DIR) && file.exists(file.path(EM_SCRIPT_DIR, 'data_stage2.R'))) {
  source(file.path(EM_SCRIPT_DIR, 'data_stage2.R'), local = TRUE) # resolve_path, path_within, stage_and_commit, fail, write_json_file
}

em_hash_ids <- function(ids) {
  f <- tempfile(fileext = '.json'); on.exit(unlink(f))
  jsonlite::write_json(as.character(ids), f, auto_unbox = TRUE, digits = NA, null = 'null', na = 'null')
  unname(tools::md5sum(f))
}

em_stage4 <- function(input, spec, output, g = NULL, n_starts = EM_DEFAULTS$n_starts, seed = EM_DEFAULTS$seed, tol = EM_DEFAULTS$tol,
                      max_iter = EM_DEFAULTS$max_iter, init = EM_DEFAULTS$init, min_effective_n = NULL,
                      max_cov_condition = EM_DEFAULTS$max_cov_condition, config_file = NULL) {
  spec_path <- resolve_path(spec); input_path <- resolve_path(input); output_path <- resolve_path(output)
  if (!file.exists(spec_path)) fail('Stage 3 spec not found: ', spec_path)
  if (!file.exists(input_path)) fail('Input CSV not found: ', input_path)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  sp <- jsonlite::fromJSON(spec_path, simplifyVector = TRUE)
  if (!isTRUE(sp$approved_for_fit)) fail('Stage 3 spec is not approved for fitting (approved_for_fit = false). Complete the Stage 3 approval first.')
  Gs <- if (is.null(g)) as.integer(sp$G_candidates) else parse_g_em(g)
  if (!all(Gs %in% sp$G_candidates)) fail('Requested G {', paste(setdiff(Gs, sp$G_candidates), collapse = ','), '} not in the approved candidates {',
                                          paste(sp$G_candidates, collapse = ','), '}; a new Stage 3 approval is required.')
  raw <- read.csv(input_path, check.names = FALSE)
  feats <- sp$features; idc <- sp$id_column
  if (!all(feats %in% names(raw))) fail('Input lacks approved features: ', paste(setdiff(feats, names(raw)), collapse = ', '))
  if (nrow(raw) != sp$input$n_rows) fail('Input has ', nrow(raw), ' rows but the approved spec has ', sp$input$n_rows, '.')
  ids <- if (!is.null(idc) && idc %in% names(raw)) raw[[idc]] else seq_len(nrow(raw))
  if (!identical(em_hash_ids(ids), sp$row_ids_md5)) fail('Row IDs differ from the approved Stage 3 specification.')
  X <- as.matrix(raw[, feats])
  if (identical(sp$scale$method, 'zscore')) {
    if (any(abs(colMeans(X)) > 1e-6) || any(abs(apply(X, 2, sd) - 1) > 1e-6)) fail('Input is not the approved z-scored matrix (means 0, SD 1 expected). Use Stage 3 transformed_data.csv.')
  } else if (!identical(unname(tools::md5sum(input_path)), sp$input$md5)) {
    fail('Input differs from the approved original-unit data (MD5 mismatch).')
  }
  fits <- em_fit(X, Gs, n_starts = n_starts, seed = seed, tol = tol, max_iter = max_iter, init = init,
                 min_effective_n = min_effective_n, max_cov_condition = max_cov_condition)

  starts <- do.call(rbind, lapply(fits, `[[`, 'starts'))
  hist <- do.call(rbind, lapply(fits, function(f) do.call(rbind, lapply(seq_along(f$histories), function(s) {
    h <- f$histories[[s]]; if (!length(h)) return(NULL)
    data.frame(G = f$G, start = s, iteration = seq_along(h) - 1L, loglik = h)
  }))))
  params <- lapply(fits, function(f) if (is.null(f$best)) NULL else list(
    G = f$G, start = f$best$start, seed = f$best$seed, loglik = f$best$loglik, iterations = f$best$iterations,
    component_order = 'decreasing mixing proportion', pi = f$best$par$pi, effective_n = f$best$par$Nk,
    mu = lapply(seq_len(f$G), function(i) as.list(f$best$par$mu[i, ])),
    Sigma = lapply(f$best$par$Sigma, function(S) unname(S)), cov_condition = em_cov_conditions(f$best$par)))
  summ <- list(stage = '4A-4B', script_version = EM_VERSION, generated_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
    spec = list(path = spec_path, spec_hash = sp$spec_hash, approval_id = sp$approval_id),
    input = list(path = input_path, md5 = unname(tools::md5sum(input_path)), n = nrow(X), p = ncol(X), features = I(feats), scale = sp$scale$method),
    covariance = 'full, component-specific, unconstrained (mclust "VVV")', G_fitted = I(Gs),
    settings = fits[[1]]$settings[c('seed', 'tol', 'max_iter', 'init', 'min_effective_n', 'max_cov_condition', 'regularization', 'convergence_rule')],
    n_starts_requested = n_starts,
    per_G = lapply(fits, `[[`, 'summary'),
    carried_warnings = list(independence = list(status = sp$rows_independent, note = sp$independence_note), outlier_policy = sp$outlier_policy),
    model_selection = 'NOT PERFORMED: BIC/AIC selection (Stage 4D) is not implemented in this step',
    gmm_fitted = TRUE, interpretation = 'none (Stage 5 not implemented)', output_dir = output_path)
  run_config <- list(script_version = EM_VERSION, input = input_path, spec = spec_path, output = output_path, g = I(Gs), n_starts = n_starts,
                     seed = seed, tol = tol, max_iter = max_iter, init = init, min_effective_n = min_effective_n,
                     max_cov_condition = max_cov_condition, config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL)
  required <- c('em_summary.json', 'fit_status.csv', 'loglik_history.csv', 'em_parameters.json', 'em_report.md', 'run_config.json',
                paste0('posterior_G', Gs[vapply(fits, function(f) !is.null(f$best), logical(1))], '.csv'))
  writer <- function(dir) {
    write_json_file(summ, file.path(dir, 'em_summary.json'))
    write.csv(starts, file.path(dir, 'fit_status.csv'), row.names = FALSE)
    write.csv(hist, file.path(dir, 'loglik_history.csv'), row.names = FALSE)
    write_json_file(Filter(Negate(is.null), params), file.path(dir, 'em_parameters.json'))
    for (f in fits) if (!is.null(f$best)) {
      tau <- f$best$tau; mx <- apply(tau, 1, max)
      post <- data.frame(ids, MAP_component = max.col(tau, ties.method = 'first'), max_posterior = mx, uncertainty = 1 - mx, tau)
      names(post) <- c(if (is.null(idc)) 'row_id' else idc, 'MAP_component', 'max_posterior', 'uncertainty', paste0('tau_', seq_len(f$G)))
      write.csv(post, file.path(dir, paste0('posterior_G', f$G, '.csv')), row.names = FALSE)
    }
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    writeLines(em_report_md(summ, fits, starts), file.path(dir, 'em_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) {
    bad <- required[!file.exists(file.path(dir, required))]
    if (length(bad)) fail('Staged EM output incomplete: ', paste(bad, collapse = ', '))
    for (f in fits) if (!is.null(f$best)) {
      post <- read.csv(file.path(dir, paste0('posterior_G', f$G, '.csv')))
      tt <- as.matrix(post[, paste0('tau_', seq_len(f$G)), drop = FALSE])
      if (nrow(tt) != nrow(X) || any(tt < 0 | tt > 1) || any(abs(rowSums(tt) - 1) > 1e-8)) fail('Posterior file for G=', f$G, ' failed validation.')
    }
  }
  stage_and_commit(output_path, writer, validator)
  invisible(list(summary = summ, fits = fits))
}

parse_g_em <- function(g) {
  g <- gsub('\\s', '', as.character(g)); out <- integer()
  for (s in strsplit(g, ',', fixed = TRUE)[[1]]) {
    if (grepl('^[0-9]+:[0-9]+$', s)) { ab <- as.integer(strsplit(s, ':')[[1]]); out <- c(out, seq(ab[1], ab[2])) }
    else if (grepl('^[0-9]+$', s)) out <- c(out, as.integer(s))
    else fail('Invalid --g value "', s, '".')
  }
  sort(unique(out))
}

em_report_md <- function(summ, fits, starts) {
  L <- c('# Stage 4A-4B - EM fits (full-covariance GMM)', '',
         sprintf('- Spec: `%s` (approval `%s`)', summ$spec$spec_hash, if (is.null(summ$spec$approval_id)) 'n/a' else summ$spec$approval_id),
         sprintf('- Data: n = %d, p = %d (%s), scale = %s', summ$input$n, summ$input$p, paste(summ$input$features, collapse = ', '), summ$input$scale),
         sprintf('- Settings: %d starts (seed %d + s - 1), init = %s, tol = %.0e, max_iter = %d, min effective n = %g, max covariance condition = %.0e, regularization = %s',
                 summ$n_starts_requested, summ$settings$seed, summ$settings$init, summ$settings$tol, summ$settings$max_iter,
                 summ$settings$min_effective_n, summ$settings$max_cov_condition, summ$settings$regularization),
         '- **No BIC/AIC or model selection was performed** (Stage 4D not implemented). Log-likelihoods of different G are not comparable as a selection criterion on their own.',
         '', '## Carried warnings', '',
         sprintf('- Independence: %s. %s', summ$carried_warnings$independence$status, if (is.null(summ$carried_warnings$independence$note)) '' else summ$carried_warnings$independence$note),
         sprintf('- Outliers: %s', summ$carried_warnings$outlier_policy),
         '', '## Per-G results', '', '| G | k_G | valid starts | best log-lik | best start (seed) | iterations | starts reaching best | distinct optima | flagged LL decreases |',
         '|---|---|---|---|---|---|---|---|---|')
  for (f in fits) {
    s <- f$summary
    L <- c(L, if (is.null(f$best)) sprintf('| %d | - | 0/%d | - | - | - | - | - | %s |', f$G, s$n_starts, s$any_ll_decrease_flagged)
           else sprintf('| %d | %d | %d/%d | %.4f | %d (%s) | %d | %d | %d | %s |', f$G, as.integer(s$k_G), s$n_valid, s$n_starts, s$best_loglik,
                        s$best_start, ifelse(is.na(s$best_seed), 'closed form', s$best_seed), f$best$iterations, s$n_reaching_best,
                        s$n_distinct_optima, if (s$any_ll_decrease_flagged) 'yes' else 'no'))
  }
  L <- c(L, '', '## Start status counts', '', paste0('| G | ', paste(EM_STATUSES, collapse = ' | '), ' |'),
         paste0('|', paste(rep('---|', length(EM_STATUSES) + 1), collapse = '')))
  for (f in fits) L <- c(L, paste0('| ', f$G, ' | ', paste(unlist(f$summary$status_counts), collapse = ' | '), ' |'))
  fails <- starts[starts$status != 'CONVERGED_VALID', ]
  if (nrow(fails)) {
    L <- c(L, '', '## Failed or non-converged starts', '', '| G | start | seed | status | reason |', '|---|---|---|---|---|',
           sprintf('| %d | %d | %s | %s | %s |', fails$G, fails$start, fails$seed, fails$status, gsub('|', '\\|', fails$reason, fixed = TRUE)))
  }
  for (f in fits) if (!is.null(f$best)) {
    b <- f$best
    L <- c(L, '', sprintf('## G = %d best solution (fitted scale)', f$G), '', '| component | pi | effective n | mean | cov condition |', '|---|---|---|---|---|',
           sprintf('| %d | %.4f | %.1f | %s | %.3g |', seq_len(f$G), b$par$pi, b$par$Nk,
                   apply(b$par$mu, 1, function(v) paste(sprintf('%.3f', v), collapse = ', ')), em_cov_conditions(b$par)))
  }
  enc2utf8(L)
}

em_cli <- function(argv) {
  keys <- c('input', 'spec', 'output', 'g', 'n-starts', 'seed', 'tol', 'max-iter', 'init', 'min-effective-n', 'max-cov-condition', 'config')
  if (length(argv) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list()
  for (i in seq(1L, length(argv), 2L)) {
    k <- argv[i]; if (!startsWith(k, '--')) fail('Expected --key, received: ', k); k <- substring(k, 3L)
    if (!k %in% keys) fail('Unknown argument --', k, '. Allowed: --', paste(keys, collapse = ', --'))
    a[[k]] <- argv[i + 1L]
  }
  if (!is.null(a$config)) {
    cfg <- jsonlite::fromJSON(resolve_path(a$config)); names(cfg) <- gsub('_', '-', names(cfg))
    bad <- setdiff(names(cfg), setdiff(keys, 'config')); if (length(bad)) fail('Unknown config key(s): ', paste(bad, collapse = ', '))
    for (k in names(cfg)) if (is.null(a[[k]])) a[[k]] <- paste(as.character(cfg[[k]]), collapse = ',')
  }
  miss <- setdiff(c('input', 'spec', 'output'), names(a)); if (length(miss)) fail('Missing settings: ', paste(miss, collapse = ', '))
  num <- function(v, d) if (is.null(v)) d else { x <- suppressWarnings(as.numeric(v)); if (is.na(x)) fail('Invalid number: ', v); x }
  em_stage4(a$input, a$spec, a$output, g = a$g, n_starts = as.integer(num(a[['n-starts']], EM_DEFAULTS$n_starts)),
            seed = as.integer(num(a$seed, EM_DEFAULTS$seed)), tol = num(a$tol, EM_DEFAULTS$tol),
            max_iter = as.integer(num(a[['max-iter']], EM_DEFAULTS$max_iter)), init = if (is.null(a$init)) EM_DEFAULTS$init else a$init,
            min_effective_n = if (is.null(a[['min-effective-n']])) NULL else num(a[['min-effective-n']], NULL),
            max_cov_condition = num(a[['max-cov-condition']], EM_DEFAULTS$max_cov_condition), config_file = a$config)
}

if (sys.nframe() == 0L) {
  res <- tryCatch(em_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
  for (s in res$summary$per_G) {
    cat(sprintf('G=%d: valid %d/%d starts', s$G, s$n_valid, s$n_starts))
    if (!is.null(s$best_loglik)) cat(sprintf(', best log-lik %.4f (start %d), %d reach best, %d distinct optima', s$best_loglik, s$best_start, s$n_reaching_best, s$n_distinct_optima))
    cat('\n')
  }
  cat('Model selection: not performed (Stage 4D pending)\n')
  cat('Output directory:', res$summary$output_dir, '\n')
}
