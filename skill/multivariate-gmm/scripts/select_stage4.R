#!/usr/bin/env Rscript
# Stage 4C (convergence diagnostics) and 4D (BIC/AIC model selection) for full-covariance GMMs.
# Uses the approved Stage 4A-4B EM (em_stage4.R) unchanged. Generic; the CLI requires an approved Stage 3 spec.
# BIC = -2 logLik + k_G log(n), AIC = -2 logLik + 2 k_G (smaller is better). mclust's BIC = 2 logLik - k_G log(n) = -BIC here.
suppressPackageStartupMessages(library(jsonlite))

s4_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
S4_SCRIPT_DIR <- dirname(s4_script_path())
source(file.path(S4_SCRIPT_DIR, 'em_stage4.R'), local = TRUE)

S4_VERSION <- '0.1.0'
# type: 'exact' = mathematical definition or rule fixed by the spec; 'heuristic' = project screening choice (not calibrated).
S4_THRESHOLDS <- list(
  bic_formula = list(value = '-2 logLik + k_G log(n)', type = 'exact', use = 'smaller is better'),
  aic_formula = list(value = '-2 logLik + 2 k_G', type = 'exact', use = 'smaller is better'),
  k_G = list(value = '(G-1) + G p + G p (p+1)/2', type = 'exact', use = 'free parameters, full covariance'),
  eligibility = list(value = 'at least one CONVERGED_VALID start', type = 'exact (spec 4D)', use = 'candidates without a valid fit are excluded from BIC/AIC'),
  min_effective_n = list(value = 'p + 1', type = 'heuristic (EM guard, Stage 4A-4B)', use = 'smaller effective component size -> DEGENERATE start'),
  max_cov_condition = list(value = 1e10, type = 'heuristic (EM guard, Stage 4A-4B)', use = 'larger condition number -> DEGENERATE start'),
  same_optimum_loglik_rel = list(value = 1e-6, type = 'heuristic (= convergence tol)', use = 'starts within this relative log-lik gap may share an optimum'),
  same_optimum_param = list(value = 1e-2, type = 'heuristic', use = 'and max |difference| of aligned pi, mu, Sigma (fitted scale) below this'),
  small_component = list(value = '5 x (p + p(p+1)/2) effective rows', type = 'heuristic (as Stage 3 S3-11)', use = 'WARNING for the selected fit of each G'),
  cov_condition_warning = list(value = 1e6, type = 'heuristic', use = 'WARNING: ill-conditioned component covariance'),
  single_start_optimum = list(value = 'best optimum reached by < 2 starts', type = 'heuristic', use = 'WARNING: optimum may not be stable'),
  failed_start_fraction = list(value = 0.5, type = 'heuristic', use = 'WARNING when more than half of the starts are not CONVERGED_VALID'),
  delta_bic_alternative = list(value = 6, type = 'heuristic (Kass & Raftery 1995 evidence scale)', use = 'eligible models with delta BIC <= 6 are kept as alternatives for Stage 6'),
  bic_evidence_scale = list(value = '0-2 weak, 2-6 positive, 6-10 strong, >10 very strong', type = 'reference (Kass & Raftery 1995)', use = 'describes delta BIC against the selected model'))

# ---------------------------------------------------------------- 4C: optimum comparison across starts
s4_perms <- function(v) if (length(v) <= 1) list(v) else do.call(c, lapply(seq_along(v), function(i) lapply(s4_perms(v[-i]), function(r) c(v[i], r))))
# Permutation q so that par$...[q] matches ref component order (minimum squared distance between means).
s4_align <- function(par, ref) {
  P <- s4_perms(seq_along(ref$pi))
  P[[which.min(vapply(P, function(q) sum((par$mu[q, , drop = FALSE] - ref$mu)^2), numeric(1)))]]
}
s4_par_diff <- function(par, ref, q) {
  c(d_pi = max(abs(par$pi[q] - ref$pi)), d_mu = max(abs(par$mu[q, , drop = FALSE] - ref$mu)),
    d_sigma = max(vapply(seq_along(q), function(i) max(abs(par$Sigma[[q[i]]] - ref$Sigma[[i]])), numeric(1))))
}

s4_start_diagnostics <- function(fit) {
  st <- fit$starts
  st$optimum <- NA_integer_; st$rel_gap_to_best <- NA_real_; st$aligned_max_d_pi <- NA_real_
  st$aligned_max_d_mu <- NA_real_; st$aligned_max_d_sigma <- NA_real_; st$label_permutation <- NA_character_; st$covariances_pd <- NA
  for (s in seq_len(nrow(st))) {
    pr <- fit$start_params[[s]]
    if (!is.null(pr) && all(is.finite(unlist(pr$Sigma)))) st$covariances_pd[s] <- all(vapply(pr$Sigma, function(S) !is.null(tryCatch(chol(S), error = function(e) NULL)), logical(1)))
  }
  if (is.null(fit$best)) return(st)
  ref <- fit$best$par; bl <- fit$best$loglik
  valid <- which(st$status == 'CONVERGED_VALID')
  reps <- list() # representatives of distinct optima: list(par, loglik)
  for (s in valid[order(-st$loglik[valid])]) {
    pr <- fit$start_params[[s]]
    q <- s4_align(pr, ref); d <- s4_par_diff(pr, ref, q)
    st$rel_gap_to_best[s] <- (bl - st$loglik[s]) / (1 + abs(bl))
    st$aligned_max_d_pi[s] <- d[['d_pi']]; st$aligned_max_d_mu[s] <- d[['d_mu']]; st$aligned_max_d_sigma[s] <- d[['d_sigma']]
    st$label_permutation[s] <- paste(q, collapse = '-')
    grp <- NA_integer_
    for (k in seq_along(reps)) {
      qk <- s4_align(pr, reps[[k]]$par); dk <- s4_par_diff(pr, reps[[k]]$par, qk)
      if (abs(reps[[k]]$loglik - st$loglik[s]) / (1 + abs(reps[[k]]$loglik)) < S4_THRESHOLDS$same_optimum_loglik_rel$value &&
          max(dk) < S4_THRESHOLDS$same_optimum_param$value) { grp <- k; break }
    }
    if (is.na(grp)) { reps[[length(reps) + 1]] <- list(par = pr, loglik = st$loglik[s]); grp <- length(reps) }
    st$optimum[s] <- grp
  }
  st
}

s4_model_warnings <- function(fit, p, st) {
  w <- character()
  if (is.null(fit$best)) return('NO_VALID_FIT: excluded from model selection')
  b <- fit$best$par; q <- p + p * (p + 1) / 2
  small <- which(b$Nk < 5 * q)
  if (length(small) && fit$G > 1) w <- c(w, sprintf('SMALL_COMPONENT: component %s effective n = %s < 5 x %g', paste(small, collapse = ','),
                                                    paste(sprintf('%.1f', b$Nk[small]), collapse = ','), q))
  cc <- em_cov_conditions(b)
  if (any(cc > S4_THRESHOLDS$cov_condition_warning$value)) w <- c(w, sprintf('ILL_CONDITIONED_COVARIANCE: max condition %.3g', max(cc)))
  nbest <- sum(st$optimum == 1L, na.rm = TRUE)
  if (fit$G > 1 && nbest < 2) w <- c(w, sprintf('SINGLE_START_OPTIMUM: best optimum reached by %d start', nbest))
  fail_frac <- mean(st$status != 'CONVERGED_VALID')
  if (fail_frac > S4_THRESHOLDS$failed_start_fraction$value) w <- c(w, sprintf('MANY_FAILED_STARTS: %.0f%% of starts not CONVERGED_VALID', 100 * fail_frac))
  if (any(st$n_ll_decreases_flagged > 0)) w <- c(w, 'LL_DECREASE_FLAGGED in at least one start')
  nopt <- length(unique(na.omit(st$optimum)))
  if (nopt > 1) w <- c(w, sprintf('MULTIPLE_LOCAL_OPTIMA: %d distinct optima among valid starts (best kept)', nopt))
  w
}

# ---------------------------------------------------------------- 4D: selection (pure function; unit-tested)
s4_bic_evidence <- function(d) ifelse(is.na(d), NA_character_, ifelse(d == 0, 'selected', ifelse(d <= 2, 'weak (0-2)',
                                 ifelse(d <= 6, 'positive (2-6)', ifelse(d <= 10, 'strong (6-10)', 'very strong (>10)')))))
s4_select <- function(tab, G_candidates, delta_alt = S4_THRESHOLDS$delta_bic_alternative$value) {
  # tab: data.frame with G, n, p, loglik (NA if no valid fit), eligible (logical)
  tab$k_G <- (tab$G - 1) + tab$G * tab$p + tab$G * tab$p * (tab$p + 1) / 2
  tab$BIC <- ifelse(tab$eligible, -2 * tab$loglik + tab$k_G * log(tab$n), NA_real_)
  tab$AIC <- ifelse(tab$eligible, -2 * tab$loglik + 2 * tab$k_G, NA_real_)
  if (!any(tab$eligible)) {
    return(list(table = tab, status = 'STOP_NO_VALID_MODELS', selected_G = NA_integer_, aic_G = NA_integer_, agree = NA,
                boundary = FALSE, alternatives = integer(), messages = 'No candidate G has a valid converged fit: model selection is not possible (STOP).'))
  }
  sel <- tab$G[which.min(ifelse(tab$eligible, tab$BIC, Inf))]; aic <- tab$G[which.min(ifelse(tab$eligible, tab$AIC, Inf))]
  tab$delta_BIC <- tab$BIC - min(tab$BIC, na.rm = TRUE); tab$delta_AIC <- tab$AIC - min(tab$AIC, na.rm = TRUE)
  tab$BIC_evidence_vs_selected <- s4_bic_evidence(tab$delta_BIC)
  tab$selected_BIC <- tab$G == sel; tab$selected_AIC <- tab$G == aic
  alts <- tab$G[tab$eligible & tab$G != sel & tab$delta_BIC <= delta_alt]
  tab$alternative_for_stage6 <- tab$G %in% alts
  boundary <- sel == max(G_candidates) && max(G_candidates) > 1
  msg <- c(sprintf('BIC selects G = %d.', sel),
           if (sel == aic) sprintf('AIC agrees (G = %d).', aic) else sprintf('AIC prefers G = %d; AIC penalises parameters less than BIC (2 vs log n = %.2f per parameter), so it tends to choose larger G.', aic, log(tab$n[1])),
           if (boundary) sprintf('BOUNDARY: the selected G equals the upper search limit (%d). A larger G might fit better; extending the search needs a new Stage 3 approval and was not done automatically.', max(G_candidates)),
           if (length(alts)) sprintf('Alternative model(s) with delta BIC <= %g kept for Stage 6 sensitivity analysis: G = %s.', delta_alt, paste(alts, collapse = ', '))
           else sprintf('No other eligible model within delta BIC <= %g.', delta_alt),
           if (any(!tab$eligible)) sprintf('Excluded (no valid fit): G = %s.', paste(tab$G[!tab$eligible], collapse = ', ')))
  list(table = tab, status = if (boundary || length(alts)) 'WARNING' else 'PASS', selected_G = sel, aic_G = aic, agree = sel == aic,
       boundary = boundary, alternatives = alts, messages = msg)
}

# ---------------------------------------------------------------- plots
s4_plot_histories <- function(fits, file) {
  G <- vapply(fits, `[[`, numeric(1), 'G'); k <- length(fits); nc <- min(3L, k); nr <- ceiling(k / nc)
  png(file, width = 520 * nc, height = 420 * nr, res = 115)
  on.exit(dev.off())
  par(mfrow = c(nr, nc), mar = c(4.2, 4.6, 3.8, 1), oma = c(0, 0, 2.2, 0), mgp = c(3, 1, 0))
  for (f in fits) {
    h <- f$histories; ok <- f$starts$status
    allv <- unlist(h[lengths(h) > 0])
    if (!length(allv)) { plot.new(); title(sprintf('G = %d: no log-likelihood recorded', f$G)); next }
    xmax <- max(1, max(lengths(h)) - 1)
    plot(NA, xlim = c(0, xmax), ylim = range(allv), xlab = 'Iteration', ylab = 'Observed log-likelihood')
    title(main = sprintf('G = %d (%d/%d valid)', f$G, sum(ok == 'CONVERGED_VALID'), length(ok)), line = 1.6)
    for (s in seq_along(h)) if (length(h[[s]])) {
      lines(seq_along(h[[s]]) - 1, h[[s]], col = if (ok[s] == 'CONVERGED_VALID') adjustcolor('grey40', .55) else adjustcolor('#C65C48', .8),
            lty = if (ok[s] == 'CONVERGED_VALID') 1 else 2, lwd = 1)
      if (length(h[[s]]) == 1) points(0, h[[s]], pch = 16, col = 'grey40')
    }
    if (!is.null(f$best)) {
      hb <- f$best$history; lines(seq_along(hb) - 1, hb, col = '#2F5D85', lwd = 2.5); points(length(hb) - 1, hb[length(hb)], pch = 19, col = '#2F5D85')
      mtext(sprintf('best final log-lik %.4f; increase from start %.3g over %d iteration(s)', hb[length(hb)], hb[length(hb)] - hb[1], length(hb) - 1),
            side = 3, line = 0.15, cex = .72, col = 'grey25')
    }
  }
  mtext('Log-likelihood histories by start (blue = best valid start; grey = other valid; red dashed = failed/not converged)', outer = TRUE, font = 2, cex = .9)
}

s4_plot_bic_aic <- function(tab, sel, aic_g, file) {
  png(file, width = 1000, height = 640, res = 120)
  on.exit(dev.off())
  par(mar = c(4.5, 5, 4, 1))
  e <- tab$eligible; yr <- range(c(tab$BIC[e], tab$AIC[e]))
  plot(tab$G, ifelse(e, tab$BIC, NA), type = 'b', pch = 19, col = '#2F5D85', lwd = 2, ylim = yr + c(-.04, .04) * diff(yr) - c(0, 0),
       xaxt = 'n', xlab = 'Number of components G', ylab = 'Criterion (smaller is better)',
       main = sprintf('BIC and AIC by G (full covariance): BIC selects G = %d, AIC selects G = %d', sel, aic_g))
  axis(1, at = tab$G)
  lines(tab$G, ifelse(e, tab$AIC, NA), type = 'b', pch = 17, col = '#C65C48', lwd = 2, lty = 2)
  points(sel, tab$BIC[tab$G == sel], pch = 1, cex = 2.6, col = '#2F5D85', lwd = 2)
  points(aic_g, tab$AIC[tab$G == aic_g], pch = 2, cex = 2.4, col = '#C65C48', lwd = 2)
  if (any(!e)) { points(tab$G[!e], rep(yr[1], sum(!e)), pch = 4, cex = 1.6); text(tab$G[!e], yr[1], 'no valid fit', pos = 3, cex = .8) }
  legend('topright', c('BIC = -2 logLik + k log n', 'AIC = -2 logLik + 2k', 'selected'), col = c('#2F5D85', '#C65C48', 'black'),
         pch = c(19, 17, 1), lty = c(1, 2, NA), lwd = 2, bty = 'n')
}

# ---------------------------------------------------------------- end-to-end
s4_read_approved <- function(input, spec) {
  spec_path <- resolve_path(spec); input_path <- resolve_path(input)
  if (!file.exists(spec_path)) fail('Stage 3 spec not found: ', spec_path)
  if (!file.exists(input_path)) fail('Input CSV not found: ', input_path)
  sp <- jsonlite::fromJSON(spec_path, simplifyVector = TRUE)
  if (!isTRUE(sp$approved_for_fit)) fail('Stage 3 spec is not approved for fitting (approved_for_fit = false). Complete the Stage 3 approval first.')
  raw <- read.csv(input_path, check.names = FALSE); feats <- sp$features; idc <- sp$id_column
  if (!all(feats %in% names(raw))) fail('Input lacks approved features: ', paste(setdiff(feats, names(raw)), collapse = ', '))
  if (nrow(raw) != sp$input$n_rows) fail('Input has ', nrow(raw), ' rows but the approved spec has ', sp$input$n_rows, '.')
  ids <- if (!is.null(idc) && idc %in% names(raw)) raw[[idc]] else seq_len(nrow(raw))
  if (!identical(em_hash_ids(ids), sp$row_ids_md5)) fail('Row IDs differ from the approved Stage 3 specification.')
  X <- as.matrix(raw[, feats])
  if (identical(sp$scale$method, 'zscore')) {
    if (any(abs(colMeans(X)) > 1e-6) || any(abs(apply(X, 2, sd) - 1) > 1e-6)) fail('Input is not the approved z-scored matrix. Use Stage 3 transformed_data.csv.')
  } else if (!identical(unname(tools::md5sum(input_path)), sp$input$md5)) fail('Input differs from the approved original-unit data (MD5 mismatch).')
  list(X = X, ids = ids, sp = sp, idc = idc, feats = feats, spec_path = spec_path, input_path = input_path)
}

stage4_select <- function(input, spec, output, g = NULL, n_starts = EM_DEFAULTS$n_starts, seed = EM_DEFAULTS$seed, tol = EM_DEFAULTS$tol,
                          max_iter = EM_DEFAULTS$max_iter, init = EM_DEFAULTS$init, min_effective_n = NULL,
                          max_cov_condition = EM_DEFAULTS$max_cov_condition, config_file = NULL) {
  output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  d <- s4_read_approved(input, spec); sp <- d$sp; X <- d$X; n <- nrow(X); p <- ncol(X)
  Gc <- as.integer(sp$G_candidates)
  Gs <- if (is.null(g)) Gc else parse_g_em(g)
  if (!all(Gs %in% Gc)) fail('Requested G {', paste(setdiff(Gs, Gc), collapse = ','), '} not in the approved candidates {', paste(Gc, collapse = ','), '}; a new Stage 3 approval is required.')
  fits <- em_fit(X, Gs, n_starts = n_starts, seed = seed, tol = tol, max_iter = max_iter, init = init,
                 min_effective_n = min_effective_n, max_cov_condition = max_cov_condition)
  diag_starts <- lapply(fits, s4_start_diagnostics)
  warns <- mapply(function(f, st) s4_model_warnings(f, p, st), fits, diag_starts, SIMPLIFY = FALSE)
  tab <- data.frame(G = Gs, n = n, p = p, loglik = vapply(fits, function(f) if (is.null(f$best)) NA_real_ else f$best$loglik, numeric(1)),
                    eligible = vapply(fits, function(f) !is.null(f$best), logical(1)))
  selr <- s4_select(tab, Gs) # boundary is judged against the largest G actually fitted (see NOTE below if < approved max)
  mt <- selr$table
  mt$n_starts <- vapply(fits, function(f) f$summary$n_starts, integer(1))
  mt$n_valid_starts <- vapply(fits, function(f) f$summary$n_valid, integer(1))
  for (stn in EM_STATUSES) mt[[paste0('n_', tolower(stn))]] <- vapply(fits, function(f) as.integer(f$summary$status_counts[[stn]]), integer(1))
  mt$best_start <- vapply(fits, function(f) if (is.null(f$best)) NA_integer_ else as.integer(f$best$start), integer(1))
  mt$n_starts_reaching_best <- vapply(diag_starts, function(st) sum(st$optimum == 1L, na.rm = TRUE), integer(1))
  mt$n_distinct_optima <- vapply(diag_starts, function(st) length(unique(na.omit(st$optimum))), integer(1))
  mt$min_pi <- vapply(fits, function(f) if (is.null(f$best)) NA_real_ else min(f$best$par$pi), numeric(1))
  mt$min_effective_n <- vapply(fits, function(f) if (is.null(f$best)) NA_real_ else min(f$best$par$Nk), numeric(1))
  mt$max_cov_condition <- vapply(fits, function(f) if (is.null(f$best)) NA_real_ else max(em_cov_conditions(f$best$par)), numeric(1))
  mt$diagnostic_warnings <- vapply(warns, function(w) if (length(w)) paste(w, collapse = ' | ') else '', character(1))
  if (!is.na(selr$selected_G) && max(Gs) < max(Gc) && selr$selected_G == max(Gs)) {
    selr$messages <- c(selr$messages, sprintf('NOTE: only G = %s were fitted; the approved range extends to %d.', paste(Gs, collapse = ','), max(Gc)))
  }
  selfit <- if (is.na(selr$selected_G)) NULL else fits[[paste0('G', selr$selected_G)]]
  conv_summary <- lapply(seq_along(fits), function(i) {
    f <- fits[[i]]; st <- diag_starts[[i]]
    list(G = f$G, eligible = !is.null(f$best), n_starts = f$summary$n_starts, status_counts = f$summary$status_counts,
         n_distinct_optima = length(unique(na.omit(st$optimum))), n_reaching_best = sum(st$optimum == 1L, na.rm = TRUE),
         label_switching_observed = any(!is.na(st$label_permutation) & st$label_permutation != paste(seq_len(f$G), collapse = '-')),
         failure_reasons = as.list(table(sub('^(iteration [0-9]+: |initial parameters: |initial E-step: )', '', st$reason[st$status != 'CONVERGED_VALID']))),
         warnings = I(warns[[i]]))
  })
  names(conv_summary) <- names(fits)
  base_info <- list(spec = list(path = d$spec_path, spec_hash = sp$spec_hash, approval_id = sp$approval_id),
                    input = list(path = d$input_path, md5 = unname(tools::md5sum(d$input_path)), n = n, p = p, features = I(d$feats), scale = sp$scale$method),
                    covariance = 'full, component-specific, unconstrained (mclust "VVV")',
                    carried_warnings = list(independence = list(status = sp$rows_independent, note = sp$independence_note), outlier_policy = sp$outlier_policy,
                                            external_label = 'not used in estimation or selection'))
  selected <- if (is.null(selfit)) NULL else c(base_info, list(
    stage = '4D', status = selr$status, selected_G = selr$selected_G, criterion = 'BIC = -2 logLik + k_G log(n), smaller is better',
    loglik = selfit$best$loglik, k_G = mt$k_G[mt$G == selr$selected_G], BIC = mt$BIC[mt$G == selr$selected_G], AIC = mt$AIC[mt$G == selr$selected_G],
    aic_selected_G = selr$aic_G, bic_aic_agree = selr$agree, boundary_optimum = selr$boundary, alternatives_for_stage6 = I(selr$alternatives),
    messages = I(selr$messages), best_start = selfit$best$start, seed = selfit$best$seed, iterations = selfit$best$iterations,
    component_order = 'decreasing mixing proportion', parameters_scale = paste('fitted scale:', sp$scale$method, '(back-transformation is Stage 5)'),
    pi = selfit$best$par$pi, effective_n = selfit$best$par$Nk, mu = lapply(seq_len(selfit$G), function(i) as.list(selfit$best$par$mu[i, ])),
    Sigma = lapply(selfit$best$par$Sigma, unname), cov_condition = em_cov_conditions(selfit$best$par),
    diagnostic_warnings = I(warns[[paste0('G', selr$selected_G)]]), interpretation = 'none (Stage 5 not implemented)'))
  all_params <- lapply(fits, function(f) if (is.null(f$best)) list(G = f$G, eligible = FALSE) else list(
    G = f$G, eligible = TRUE, loglik = f$best$loglik, start = f$best$start, seed = f$best$seed, pi = f$best$par$pi, effective_n = f$best$par$Nk,
    mu = lapply(seq_len(f$G), function(i) as.list(f$best$par$mu[i, ])), Sigma = lapply(f$best$par$Sigma, unname)))
  hist <- do.call(rbind, lapply(fits, function(f) do.call(rbind, lapply(seq_along(f$histories), function(s) {
    h <- f$histories[[s]]; if (!length(h)) return(NULL)
    data.frame(G = f$G, start = s, status = f$starts$status[s], best_start = !is.null(f$best) && f$best$start == s, iteration = seq_along(h) - 1L, loglik = h)
  }))))
  conv_starts <- do.call(rbind, diag_starts)
  run_config <- list(script_version = S4_VERSION, em_version = EM_VERSION, input = d$input_path, spec = d$spec_path, output = output_path,
                     g = I(Gs), n_starts = n_starts, seed = seed, tol = tol, max_iter = max_iter, init = init,
                     min_effective_n = if (is.null(min_effective_n)) p + 1 else min_effective_n, max_cov_condition = max_cov_condition,
                     config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL, r_version = R.version.string)
  conv_json <- c(base_info, list(stage = '4C', per_G = conv_summary, thresholds = S4_THRESHOLDS,
                                 settings = fits[[1]]$settings[c('seed', 'tol', 'max_iter', 'init', 'min_effective_n', 'max_cov_condition', 'regularization', 'convergence_rule')]))
  required <- c('model_comparison.csv', 'convergence_diagnostics.csv', 'convergence_summary.json', 'loglik_history.csv', 'loglik_histories.png',
                'bic_aic.png', 'all_models_parameters.json', 'selection_report.md', 'run_config.json')
  if (!is.null(selfit)) required <- c(required, 'selected_model.json', 'selected_model.rds', 'posterior_selected.csv')
  writer <- function(dir) {
    write.csv(mt, file.path(dir, 'model_comparison.csv'), row.names = FALSE)
    write.csv(conv_starts, file.path(dir, 'convergence_diagnostics.csv'), row.names = FALSE)
    write_json_file(conv_json, file.path(dir, 'convergence_summary.json'))
    write.csv(hist, file.path(dir, 'loglik_history.csv'), row.names = FALSE)
    s4_plot_histories(fits, file.path(dir, 'loglik_histories.png'))
    if (any(mt$eligible)) s4_plot_bic_aic(mt, selr$selected_G, selr$aic_G, file.path(dir, 'bic_aic.png'))
    else { png(file.path(dir, 'bic_aic.png')); plot.new(); title('No eligible model: BIC/AIC not computed'); dev.off() }
    write_json_file(all_params, file.path(dir, 'all_models_parameters.json'))
    if (!is.null(selfit)) {
      write_json_file(selected, file.path(dir, 'selected_model.json'))
      saveRDS(list(G = selfit$G, par = selfit$best$par, loglik = selfit$best$loglik, features = d$feats, scale = sp$scale,
                   spec_hash = sp$spec_hash, settings = selfit$settings, row_ids = d$ids), file.path(dir, 'selected_model.rds'))
      tau <- selfit$best$tau; mx <- apply(tau, 1, max)
      post <- data.frame(d$ids, max.col(tau, ties.method = 'first'), mx, 1 - mx, tau)
      names(post) <- c(if (is.null(d$idc)) 'row_id' else d$idc, 'MAP_component', 'max_posterior', 'uncertainty', paste0('tau_', seq_len(selfit$G)))
      write.csv(post, file.path(dir, 'posterior_selected.csv'), row.names = FALSE)
    }
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    writeLines(s4_report_md(base_info, mt, selr, conv_summary, conv_starts, fits), file.path(dir, 'selection_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) {
    bad <- required[!file.exists(file.path(dir, required))]
    if (length(bad)) fail('Staged Stage 4C-4D output incomplete: ', paste(bad, collapse = ', '))
    chk <- read.csv(file.path(dir, 'model_comparison.csv'))
    if (nrow(chk) != length(Gs)) fail('model_comparison.csv failed validation.')
  }
  stage_and_commit(output_path, writer, validator)
  invisible(list(table = mt, selection = selr, fits = fits, diagnostics = diag_starts, warnings = warns, output_dir = output_path))
}

s4_report_md <- function(info, mt, selr, conv, cst, fits) {
  f <- function(x, d = 2) ifelse(is.na(x), '-', formatC(x, format = 'f', digits = d))
  L <- c('# Stage 4C-4D - Convergence diagnostics and model selection', '',
         sprintf('- Spec `%s` (approval `%s`); data n = %d, p = %d, scale = %s; covariance: %s', info$spec$spec_hash,
                 if (is.null(info$spec$approval_id)) 'n/a' else info$spec$approval_id, info$input$n, info$input$p, info$input$scale, info$covariance),
         sprintf('- **Selection status: %s** - %s', selr$status, paste(selr$messages, collapse = ' ')),
         '- BIC = -2 logLik + k_G log(n); AIC = -2 logLik + 2 k_G; smaller is better. (mclust reports BIC with the opposite sign.)',
         '- No interpretation of components and no external-label comparison were performed (Stages 5-6).',
         '', '## Carried warnings', '',
         sprintf('- Independence: %s. %s', info$carried_warnings$independence$status, if (is.null(info$carried_warnings$independence$note)) '' else info$carried_warnings$independence$note),
         sprintf('- Outliers: %s. External label: %s.', info$carried_warnings$outlier_policy, info$carried_warnings$external_label),
         '', '## Model comparison', '',
         '| G | k_G | log-lik | BIC | delta BIC | evidence vs selected | AIC | delta AIC | valid starts | reach best | distinct optima | min pi | min eff. n | max cov cond. | selected |',
         '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|',
         sprintf('| %d | %d | %s | %s | %s | %s | %s | %s | %d/%d | %d | %d | %s | %s | %s | %s |', mt$G, as.integer(mt$k_G), f(mt$loglik, 3), f(mt$BIC), f(mt$delta_BIC),
                 ifelse(is.na(mt$BIC_evidence_vs_selected), 'excluded', mt$BIC_evidence_vs_selected), f(mt$AIC), f(mt$delta_AIC), mt$n_valid_starts, mt$n_starts,
                 mt$n_starts_reaching_best, mt$n_distinct_optima, f(mt$min_pi, 3), f(mt$min_effective_n, 1), formatC(mt$max_cov_condition, format = 'g', digits = 3),
                 paste0(ifelse(mt$selected_BIC %in% TRUE, 'BIC ', ''), ifelse(mt$selected_AIC %in% TRUE, 'AIC ', ''), ifelse(mt$alternative_for_stage6 %in% TRUE, 'alt', ''))),
         '', '## Convergence diagnostics (Stage 4C)', '', '| G | status counts | distinct optima | label switching across starts | warnings |', '|---|---|---|---|---|')
  for (cs in conv) {
    sc <- paste(sprintf('%s=%d', names(cs$status_counts), unlist(cs$status_counts))[unlist(cs$status_counts) > 0], collapse = ', ')
    L <- c(L, sprintf('| %d | %s | %d | %s | %s |', cs$G, sc, cs$n_distinct_optima, if (cs$label_switching_observed) 'yes (handled by alignment)' else 'no',
                      if (length(cs$warnings)) gsub('|', '/', paste(cs$warnings, collapse = '; '), fixed = TRUE) else '-'))
  }
  opt <- cst[!is.na(cst$optimum), ]
  if (nrow(opt)) {
    agg <- do.call(rbind, lapply(split(opt, list(opt$G, opt$optimum), drop = TRUE), function(d)
      data.frame(G = d$G[1], optimum = d$optimum[1], starts = nrow(d), loglik = max(d$loglik))))
    agg <- agg[order(agg$G, agg$optimum), ]
    L <- c(L, '', '### Distinct optima per G (after label alignment)', '', '| G | optimum | starts | log-lik |', '|---|---|---|---|',
           sprintf('| %d | %d | %d | %.4f |', agg$G, agg$optimum, as.integer(agg$starts), agg$loglik))
  }
  fl <- cst[cst$status != 'CONVERGED_VALID', ]
  if (nrow(fl)) L <- c(L, '', '### Failed / non-converged starts', '', '| G | start | status | reason |', '|---|---|---|---|',
                       sprintf('| %d | %d | %s | %s |', fl$G, fl$start, fl$status, gsub('|', '/', fl$reason, fixed = TRUE)))
  L <- c(L, '', '## Thresholds', '', '| Name | Value | Type | Use |', '|---|---|---|---|',
         vapply(names(S4_THRESHOLDS), function(k) { t <- S4_THRESHOLDS[[k]]; sprintf('| %s | %s | %s | %s |', k, format(t$value), t$type, t$use) }, character(1)))
  enc2utf8(L)
}

s4_cli <- function(argv) {
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
  stage4_select(a$input, a$spec, a$output, g = a$g, n_starts = as.integer(num(a[['n-starts']], EM_DEFAULTS$n_starts)),
                seed = as.integer(num(a$seed, EM_DEFAULTS$seed)), tol = num(a$tol, EM_DEFAULTS$tol),
                max_iter = as.integer(num(a[['max-iter']], EM_DEFAULTS$max_iter)), init = if (is.null(a$init)) EM_DEFAULTS$init else a$init,
                min_effective_n = if (is.null(a[['min-effective-n']])) NULL else num(a[['min-effective-n']], NULL),
                max_cov_condition = num(a[['max-cov-condition']], EM_DEFAULTS$max_cov_condition), config_file = a$config)
}

if (sys.nframe() == 0L) {
  r <- tryCatch(s4_cli(commandArgs(trailingOnly = TRUE)), error = function(e) gmm_cli_error(e, 'stage4'))
  m <- r$table; none <- identical(r$selection$status, 'STOP_NO_VALID_MODELS')
  if (none) print(format(data.frame(G = m$G, k_G = m$k_G, valid = paste0(m$n_valid_starts, '/', m$n_starts), invalid_start = m$n_invalid_start, degenerate = m$n_degenerate, not_converged = m$n_not_converged, numeric_error = m$n_numeric_error)), row.names = FALSE)
  else print(format(data.frame(G = m$G, k_G = m$k_G, loglik = round(m$loglik, 3), BIC = round(m$BIC, 2), AIC = round(m$AIC, 2),
                               dBIC = round(m$delta_BIC, 2), valid = paste0(m$n_valid_starts, '/', m$n_starts), optima = m$n_distinct_optima)), row.names = FALSE)
  cat(paste(r$selection$messages, collapse = '\n'), '\n')
  cat('Output directory:', r$output_dir, '\n')
  if (none) gmm_finish('BLOCKED', 'stage4', 'STOP_NO_VALID_MODELS', 'Review convergence_diagnostics.csv; refit into a new directory with other numerical settings, or revise the candidate G under a new Stage 3 approval.')
  gmm_finish('SUCCESS', 'stage4', r$selection$status, 'Present convergence and BIC/AIC to the user; Stage 5 after confirmation.')
}
