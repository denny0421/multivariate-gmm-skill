#!/usr/bin/env Rscript
# Stage 4 convergence confirmation (diagnostic only). For every CONVERGED_VALID start of an existing Stage 4C-4D run:
#   1. replay it with its original seed and settings and verify status, iterations and log-likelihood;
#   2. continue from the replayed end point with the unchanged EM (em_run) under a stricter tolerance;
#   3. classify the same-start gain = strict log-likelihood - original log-likelihood.
# It never changes em_stage4.R / select_stage4.R / workflow.R behaviour, never writes into the Stage 4 directory, never writes
# selected_model.rds and never touches workflow_state.json. To adopt a model, fit it with select_stage4.R into a new directory
# and use workflow.R register-model / activate-model --approved true.
suppressPackageStartupMessages(library(jsonlite))

confirm_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
CONFIRM_SCRIPT_DIR <- dirname(confirm_script_path())
source(file.path(CONFIRM_SCRIPT_DIR, 'select_stage4.R'), local = TRUE)

CONFIRM_VERSION <- '0.1.0'
CONFIRM_DEFAULTS <- list(strict_tol = 1e-8, strict_max_iter = 5000L, premature_gain_abs = 0.1, replay_match_abs = 1e-8)
# All four values are project-chosen heuristics, not statistical tests.
CONFIRM_THRESHOLDS <- list(
  strict_tol = list(value = CONFIRM_DEFAULTS$strict_tol, type = 'heuristic', use = 'stricter relative log-likelihood tolerance used to continue each valid start'),
  strict_max_iter = list(value = CONFIRM_DEFAULTS$strict_max_iter, type = 'heuristic', use = 'total EM iterations allowed per start, counted from its initialisation'),
  premature_gain_abs = list(value = CONFIRM_DEFAULTS$premature_gain_abs, type = 'heuristic (not a statistical test)', use = 'same-start gain >= this -> POSSIBLE_PREMATURE_STOP; also the margin for BETTER_OPTIMUM_HIDDEN and AT_STRICT_BEST'),
  replay_match_abs = list(value = CONFIRM_DEFAULTS$replay_match_abs, type = 'heuristic', use = 'largest |replay - recorded| log-likelihood accepted as the same run'))
CONFIRM_USABLE <- c('NO_MATERIAL_CHANGE', 'POSSIBLE_PREMATURE_STOP', 'CLOSED_FORM_NOT_ITERATIVE')
CONFIRM_CLASSES <- c('NO_MATERIAL_CHANGE', 'POSSIBLE_PREMATURE_STOP', 'STRICT_NOT_CONVERGED', 'STRICT_DEGENERATE', 'STRICT_NUMERIC_ERROR',
                     'REPLAY_MISMATCH', 'NOT_ELIGIBLE', 'CLOSED_FORM_NOT_ITERATIVE')

# ---------------------------------------------------------------- pure rules
confirm_classify <- function(replay_ok, strict_status, gain, delta = CONFIRM_DEFAULTS$premature_gain_abs) {
  if (!isTRUE(replay_ok)) return('REPLAY_MISMATCH')
  switch(strict_status,
    CONVERGED_VALID = if (is.finite(gain) && gain >= delta) 'POSSIBLE_PREMATURE_STOP' else if (is.finite(gain)) 'NO_MATERIAL_CHANGE' else 'STRICT_NUMERIC_ERROR',
    NOT_CONVERGED = 'STRICT_NOT_CONVERGED',
    DEGENERATE = 'STRICT_DEGENERATE',
    'STRICT_NUMERIC_ERROR') # NUMERIC_ERROR, or an end point the guards reject
}

# Aitken estimate of the log-likelihood still to come under locally linear convergence; descriptive only.
confirm_aitken <- function(h) {
  n <- length(h); if (n < 3L) return(NA_real_)
  d1 <- h[n] - h[n - 1L]; d0 <- h[n - 1L] - h[n - 2L]; r <- d1 / d0
  if (!is.finite(r) || r <= 0 || r >= 1) return(NA_real_)
  d1 * r / (1 - r)
}

confirm_blank <- function(o) data.frame(G = o$G, start = o$start, seed = o$seed, original_status = o$status, original_iterations = as.integer(o$iterations), original_loglik = o$loglik,
  replay_status = NA_character_, replay_iterations = NA_integer_, replay_loglik = NA_real_, replay_match = NA,
  strict_status = NA_character_, additional_iterations = NA_integer_, total_iterations = NA_integer_, strict_loglik = NA_real_,
  gain = NA_real_, delta_BIC_fixed_G = NA_real_, classification = NA_character_, strict_role = NA_character_, gap_to_strict_best = NA_real_,
  aligned_param_move = NA_real_, final_rel_change = NA_real_, aitken_remaining = NA_real_, next_step_max_d_pi = NA_real_, next_step_max_d_mu = NA_real_,
  next_step_max_d_sigma = NA_real_, reason = NA_character_, stringsAsFactors = FALSE)

# Confirm one start. `continue_fun` defaults to the unchanged em_run; tests may inject a failing path.
confirm_one <- function(X, o, settings, strict_tol, strict_max_iter, delta, match_abs, continue_fun = em_run) {
  r <- confirm_blank(o); p <- ncol(X); G <- o$G; mn <- settings$min_effective_n; mc <- settings$max_cov_condition
  if (o$status != 'CONVERGED_VALID') {
    r$classification <- 'NOT_ELIGIBLE'; r$reason <- sprintf('original status %s: not a converged valid start, status kept as recorded', o$status); return(r)
  }
  if (G == 1L) { # closed-form MLE: there is no iteration to continue
    par <- em_mstep(X, matrix(1, nrow(X), 1L)); e <- em_estep(X, par)
    r$replay_status <- if (is.null(em_check(par, p, mn, mc)) && e$ok) 'CONVERGED_VALID' else 'NUMERIC_ERROR'
    r$replay_iterations <- 1L; r$replay_loglik <- if (e$ok) e$loglik else NA_real_
    r$replay_match <- r$replay_status == 'CONVERGED_VALID' && abs(r$replay_loglik - o$loglik) <= match_abs
    if (!r$replay_match) { r$classification <- 'REPLAY_MISMATCH'; r$reason <- 'closed-form fit differs from the recorded log-likelihood'; return(r) }
    r$strict_status <- 'CONVERGED_VALID'; r$additional_iterations <- 0L; r$total_iterations <- 1L; r$strict_loglik <- r$replay_loglik
    r$gain <- r$strict_loglik - o$loglik; r$delta_BIC_fixed_G <- -2 * r$gain
    r$classification <- 'CLOSED_FORM_NOT_ITERATIVE'; r$reason <- 'single-Gaussian MLE in closed form; nothing to iterate'; return(r)
  }
  rp <- with_seed(as.integer(o$seed), {
    ini <- em_init(X, G, settings$init, mn)
    if (is.null(ini$par)) list(status = ini$status, iterations = 0L, loglik = NA_real_, reason = ini$reason, par = NULL, history = numeric())
    else em_run(X, ini$par, settings$tol, settings$max_iter, mn, mc)
  })
  r$replay_status <- rp$status; r$replay_iterations <- as.integer(rp$iterations); r$replay_loglik <- rp$loglik
  ok <- identical(rp$status, o$status) && r$replay_iterations == r$original_iterations && is.finite(rp$loglik) && abs(rp$loglik - o$loglik) <= match_abs
  r$replay_match <- ok
  if (!ok) {
    r$classification <- 'REPLAY_MISMATCH'
    r$reason <- sprintf('replay gave status %s, %d iterations, log-lik %.10g; recorded %s, %d, %.10g', rp$status, r$replay_iterations, rp$loglik, o$status, r$original_iterations, o$loglik)
    return(r)
  }
  h <- rp$history
  if (length(h) >= 2L) r$final_rel_change <- abs(h[length(h)] - h[length(h) - 1L]) / (1 + abs(h[length(h) - 1L]))
  r$aitken_remaining <- confirm_aitken(h)
  e0 <- em_estep(X, rp$par); nx <- em_mstep(X, e0$tau)
  r$next_step_max_d_pi <- max(abs(nx$pi - rp$par$pi)); r$next_step_max_d_mu <- max(abs(nx$mu - rp$par$mu))
  r$next_step_max_d_sigma <- max(vapply(seq_along(nx$Sigma), function(i) max(abs(nx$Sigma[[i]] - rp$par$Sigma[[i]])), numeric(1)))
  remaining <- as.integer(strict_max_iter) - r$replay_iterations
  if (remaining < 1L) {
    r$strict_status <- 'NOT_CONVERGED'; r$additional_iterations <- 0L; r$total_iterations <- r$replay_iterations
    r$classification <- 'STRICT_NOT_CONVERGED'; r$reason <- 'no iterations left under strict_max_iter'; return(r)
  }
  st <- continue_fun(X, rp$par, strict_tol, remaining, mn, mc)
  status <- st$status
  if (status == 'CONVERGED_VALID' && (!is.finite(st$loglik) || !is.null(em_check(st$par, p, mn, mc)))) status <- 'NUMERIC_ERROR' # the end point must pass every EM guard
  r$strict_status <- status; r$additional_iterations <- as.integer(st$iterations); r$total_iterations <- r$replay_iterations + r$additional_iterations
  if (status == 'CONVERGED_VALID') {
    r$strict_loglik <- st$loglik; r$gain <- st$loglik - o$loglik; r$delta_BIC_fixed_G <- -2 * r$gain
    r$aligned_param_move <- max(s4_par_diff(st$par, rp$par, s4_align(st$par, rp$par)))
  }
  r$classification <- confirm_classify(TRUE, status, r$gain, delta)
  r$reason <- st$reason
  r
}

confirm_starts <- function(X, orig, settings, strict_tol = CONFIRM_DEFAULTS$strict_tol, strict_max_iter = CONFIRM_DEFAULTS$strict_max_iter,
                           delta = CONFIRM_DEFAULTS$premature_gain_abs, match_abs = CONFIRM_DEFAULTS$replay_match_abs, continue_fun = em_run) {
  X <- as.matrix(X); storage.mode(X) <- 'double'
  if (!(strict_tol > 0) || strict_tol >= settings$tol) fail('strict_tol must be positive and smaller than the original tol (', settings$tol, ').')
  if (strict_max_iter < 1) fail('strict_max_iter must be at least 1.')
  st <- do.call(rbind, lapply(seq_len(nrow(orig)), function(i) confirm_one(X, orig[i, ], settings, strict_tol, strict_max_iter, delta, match_abs, continue_fun)))
  for (g in unique(st$G)) {
    k <- which(st$G == g & st$classification %in% CONFIRM_USABLE)
    if (!length(k)) next
    b <- max(st$strict_loglik[k]); st$gap_to_strict_best[k] <- b - st$strict_loglik[k]
    st$strict_role[k] <- ifelse(st$gap_to_strict_best[k] < delta, 'AT_STRICT_BEST', 'BELOW_STRICT_BEST')
  }
  rownames(st) <- NULL
  st
}

# Per-G comparison. Only starts that passed the replay and the strict validity checks enter the strict column.
confirm_by_G <- function(st, Gs, n, p, delta = CONFIRM_DEFAULTS$premature_gain_abs) {
  rows <- lapply(Gs, function(g) {
    d <- st[st$G == g, ]; ov <- which(d$original_status == 'CONVERGED_VALID'); sv <- which(d$classification %in% CONFIRM_USABLE)
    ob <- if (length(ov)) ov[which.max(d$original_loglik[ov])] else NA_integer_
    sb <- if (length(sv)) sv[which.max(d$strict_loglik[sv])] else NA_integer_
    oll <- if (is.na(ob)) NA_real_ else d$original_loglik[ob]; sll <- if (is.na(sb)) NA_real_ else d$strict_loglik[sb]
    b_ref <- if (!is.na(ob) && d$classification[ob] %in% CONFIRM_USABLE) d$strict_loglik[ob] else oll
    others <- setdiff(sv, ob)
    hidden <- length(others) > 0L && !is.na(ob) && max(d$strict_loglik[others]) - b_ref >= delta
    premature <- !is.na(ob) && identical(d$classification[ob], 'POSSIBLE_PREMATURE_STOP')
    data.frame(G = g, original_best_start = if (is.na(ob)) NA_integer_ else d$start[ob], original_loglik = oll,
      original_best_class = if (is.na(ob)) NA_character_ else d$classification[ob],
      strict_best_start = if (is.na(sb)) NA_integer_ else d$start[sb], strict_loglik = sll,
      delta_loglik = sll - oll, delta_BIC_fixed_G = -2 * (sll - oll), delta_AIC_fixed_G = -2 * (sll - oll),
      ORIGINAL_BEST_PREMATURE = premature, BETTER_OPTIMUM_HIDDEN = hidden,
      n_valid_original = length(ov), n_usable_strict = length(sv),
      n_possible_premature = sum(d$classification == 'POSSIBLE_PREMATURE_STOP'), n_no_material_change = sum(d$classification == 'NO_MATERIAL_CHANGE'),
      n_below_strict_best_no_change = sum(d$classification == 'NO_MATERIAL_CHANGE' & d$strict_role %in% 'BELOW_STRICT_BEST'),
      n_strict_not_converged = sum(d$classification == 'STRICT_NOT_CONVERGED'), n_strict_degenerate = sum(d$classification == 'STRICT_DEGENERATE'),
      n_strict_numeric_error = sum(d$classification == 'STRICT_NUMERIC_ERROR'), n_replay_mismatch = sum(d$classification == 'REPLAY_MISMATCH'),
      n_not_eligible = sum(d$classification == 'NOT_ELIGIBLE'), comparison_complete = length(ov) == length(sv), stringsAsFactors = FALSE)
  })
  tab <- do.call(rbind, rows)
  so <- s4_select(data.frame(G = tab$G, n = n, p = p, loglik = tab$original_loglik, eligible = !is.na(tab$original_loglik)), Gs)
  ss <- s4_select(data.frame(G = tab$G, n = n, p = p, loglik = tab$strict_loglik, eligible = !is.na(tab$strict_loglik)), Gs)
  tab$k_G <- so$table$k_G; tab$original_BIC <- so$table$BIC; tab$original_AIC <- so$table$AIC; tab$strict_BIC <- ss$table$BIC; tab$strict_AIC <- ss$table$AIC
  sel <- list(original = list(BIC_G = so$selected_G, AIC_G = so$aic_G), strict = list(BIC_G = ss$selected_G, AIC_G = ss$aic_G),
              BIC_preference_changed = !identical(so$selected_G, ss$selected_G), AIC_preference_changed = !identical(so$aic_G, ss$aic_G),
              all_valid_starts_confirmed = all(tab$comparison_complete),
              excluded_from_strict_comparison = I(tab$G[is.na(tab$strict_loglik)]))
  list(table = tab, selection = sel)
}

# ---------------------------------------------------------------- end-to-end
confirm_md5s <- function(d) { f <- sort(list.files(d, recursive = TRUE, full.names = TRUE)); setNames(unname(tools::md5sum(f)), basename(f)) }

confirm_stage4 <- function(stage4_dir, input, spec, output, g = NULL, strict_tol = CONFIRM_DEFAULTS$strict_tol, strict_max_iter = CONFIRM_DEFAULTS$strict_max_iter,
                           config_file = NULL, delta = CONFIRM_DEFAULTS$premature_gain_abs, match_abs = CONFIRM_DEFAULTS$replay_match_abs, continue_fun = em_run) {
  dir4 <- resolve_path(stage4_dir); output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (path_within(output_path, dir4)) fail('Output path is inside the Stage 4 directory, which is read-only for this module.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  need <- file.path(dir4, c('run_config.json', 'convergence_diagnostics.csv', 'convergence_summary.json', 'model_comparison.csv'))
  if (any(!file.exists(need))) fail('Stage 4C-4D directory incomplete, missing: ', paste(basename(need[!file.exists(need)]), collapse = ', '))
  d <- s4_read_approved(input, spec); X <- d$X; n <- nrow(X); p <- ncol(X)
  cs <- jsonlite::fromJSON(need[3], simplifyVector = TRUE); rc <- jsonlite::fromJSON(need[1], simplifyVector = TRUE)
  if (!identical(cs$spec$spec_hash, d$sp$spec_hash)) fail('Spec hash mismatch between the Stage 4 output and --spec.')
  if (!identical(cs$input$md5, unname(tools::md5sum(d$input_path)))) fail('Data mismatch: --input differs from the file used by this Stage 4 run (MD5).')
  settings <- list(tol = rc$tol, max_iter = as.integer(rc$max_iter), init = rc$init, seed = as.integer(rc$seed), n_starts = as.integer(rc$n_starts),
                   min_effective_n = rc$min_effective_n, max_cov_condition = rc$max_cov_condition)
  orig <- read.csv(need[2], stringsAsFactors = FALSE)
  Gs <- sort(unique(orig$G))
  if (!is.null(g)) { req <- parse_g_em(g); if (!all(req %in% Gs)) fail('Requested G {', paste(setdiff(req, Gs), collapse = ','), '} was not fitted in this Stage 4 run.'); Gs <- req }
  orig <- orig[orig$G %in% Gs, ]
  h0 <- confirm_md5s(dir4)
  st <- confirm_starts(X, orig, settings, strict_tol, strict_max_iter, delta, match_abs, continue_fun)
  byg <- confirm_by_G(st, Gs, n, p, delta); tab <- byg$table
  mc <- read.csv(need[4]); mc <- mc[match(Gs, mc$G), ]
  if (any(abs(mc$loglik - tab$original_loglik) > match_abs, na.rm = TRUE)) fail('convergence_diagnostics.csv and model_comparison.csv disagree on the best log-likelihood.')
  thr <- CONFIRM_THRESHOLDS
  thr$strict_tol$value <- strict_tol; thr$strict_max_iter$value <- strict_max_iter; thr$premature_gain_abs$value <- delta; thr$replay_match_abs$value <- match_abs
  summ <- list(stage = '4-confirmation', script_version = CONFIRM_VERSION, em_version = EM_VERSION, diagnostic_only = TRUE, active_model_changed = FALSE, selected_model_written = FALSE,
    adoption_path = 'fit with select_stage4.R into a new directory, then workflow.R register-model and activate-model --approved true',
    source_stage4 = list(dir = dir4, files_md5 = as.list(h0)), spec = list(path = d$spec_path, spec_hash = d$sp$spec_hash, approval_id = d$sp$approval_id),
    input = list(path = d$input_path, md5 = unname(tools::md5sum(d$input_path)), n = n, p = p, features = I(d$feats)),
    original_settings = settings, strict_settings = list(strict_tol = strict_tol, strict_max_iter = strict_max_iter),
    thresholds = thr, classification_counts = as.list(table(factor(st$classification, levels = CONFIRM_CLASSES))),
    per_G = lapply(seq_len(nrow(tab)), function(i) as.list(tab[i, ])), selection = byg$selection,
    interpretation = c('POSSIBLE_PREMATURE_STOP is a project heuristic on the same-start gain; it is not a statistically significant improvement.',
                       'NO_MATERIAL_CHANGE means no gain of at least the threshold under this strictness; it does not prove that a local maximum was reached.',
                       'Delta BIC at fixed G equals -2 x delta log-likelihood because k_G and n do not change.',
                       'Only starts that passed the replay and the strict validity checks enter the strict BIC/AIC comparison.'))
  run_config <- list(script_version = CONFIRM_VERSION, stage4_dir = dir4, input = d$input_path, spec = d$spec_path, output = output_path, g = I(Gs),
                     strict_tol = strict_tol, strict_max_iter = strict_max_iter, premature_gain_abs = delta, replay_match_abs = match_abs,
                     config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL, r_version = R.version.string)
  files <- c('confirmation_starts.csv', 'confirmation_by_G.csv', 'confirmation_summary.json', 'confirmation_report.md', 'run_config.json')
  writer <- function(dir) {
    write.csv(st, file.path(dir, 'confirmation_starts.csv'), row.names = FALSE)
    write.csv(tab, file.path(dir, 'confirmation_by_G.csv'), row.names = FALSE)
    write_json_file(summ, file.path(dir, 'confirmation_summary.json'))
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    writeLines(confirm_report_md(summ, st, tab, byg$selection), file.path(dir, 'confirmation_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) {
    bad <- files[!file.exists(file.path(dir, files))]
    if (length(bad)) fail('Staged confirmation output incomplete: ', paste(bad, collapse = ', '))
    if (nrow(read.csv(file.path(dir, 'confirmation_starts.csv'))) != nrow(st)) fail('confirmation_starts.csv failed validation.')
    if (!identical(confirm_md5s(dir4), h0)) fail('The Stage 4 directory changed during confirmation.')
  }
  stage_and_commit(output_path, writer, validator)
  invisible(list(starts = st, by_G = tab, selection = byg$selection, summary = summ, output_dir = output_path))
}

confirm_report_md <- function(summ, st, tab, sel) {
  f <- function(x, d = 4) ifelse(is.na(x), '-', formatC(x, format = 'f', digits = d))
  e <- function(x) ifelse(is.na(x), '-', formatC(x, format = 'e', digits = 2))
  flag <- function(i) { v <- c(if (tab$ORIGINAL_BEST_PREMATURE[i]) 'ORIGINAL_BEST_PREMATURE', if (tab$BETTER_OPTIMUM_HIDDEN[i]) 'BETTER_OPTIMUM_HIDDEN'); if (length(v)) paste(v, collapse = ', ') else '-' }
  grp <- do.call(rbind, lapply(split(st, list(st$G, st$classification), drop = TRUE), function(d) data.frame(G = d$G[1], classification = d$classification[1], n = nrow(d), starts = paste(d$start, collapse = ', '), stringsAsFactors = FALSE)))
  grp <- grp[order(grp$G, grp$classification), ]
  L <- c('# Stage 4 convergence confirmation (diagnostic only)', '',
         sprintf('- Source: `%s`', summ$source_stage4$dir),
         sprintf('- Spec `%s`; data n = %d, p = %d', summ$spec$spec_hash, summ$input$n, summ$input$p),
         sprintf('- Original: tol = %.0e, max_iter = %d, seed = %d, init = %s. Strict: tol = %.0e, max_iter = %d (total per start).',
                 summ$original_settings$tol, summ$original_settings$max_iter, summ$original_settings$seed, summ$original_settings$init, summ$strict_settings$strict_tol, summ$strict_settings$strict_max_iter),
         '- **Diagnostic only.** No Stage 4 output, approved model or Active Model was changed, and no `selected_model.rds` was written. Adoption requires a new Stage 4 fit, `register-model` and user-approved `activate-model`.',
         paste0('- ', summ$interpretation), '',
         '## Per-G comparison', '',
         '| G | original log-lik (start) | strict log-lik (start) | delta log-lik | delta BIC at fixed G | original BIC | strict BIC | original AIC | strict AIC | flags | all valid starts confirmed |',
         '|---|---|---|---|---|---|---|---|---|---|---|',
         sprintf('| %d | %s (%s) | %s (%s) | %s | %s | %s | %s | %s | %s | %s | %s |', tab$G, f(tab$original_loglik), ifelse(is.na(tab$original_best_start), '-', tab$original_best_start),
                 f(tab$strict_loglik), ifelse(is.na(tab$strict_best_start), '-', tab$strict_best_start), f(tab$delta_loglik), f(tab$delta_BIC_fixed_G), f(tab$original_BIC, 3), f(tab$strict_BIC, 3),
                 f(tab$original_AIC, 3), f(tab$strict_AIC, 3), vapply(seq_len(nrow(tab)), flag, ''), ifelse(tab$comparison_complete, 'yes', 'no')),
         '', '## Preferred G', '', '| Criterion | Original | After strict confirmation | Changed |', '|---|---|---|---|',
         sprintf('| BIC | %s | %s | %s |', sel$original$BIC_G, sel$strict$BIC_G, if (sel$BIC_preference_changed) 'yes' else 'no'),
         sprintf('| AIC | %s | %s | %s |', sel$original$AIC_G, sel$strict$AIC_G, if (sel$AIC_preference_changed) 'yes' else 'no'),
         '', if (sel$all_valid_starts_confirmed) 'All valid starts passed the replay and strict validity checks.' else '**Not every valid start could be confirmed; the strict column uses only the confirmed starts.**',
         '', '## Classification by G', '', '| G | classification | starts (n) | start IDs |', '|---|---|---|---|',
         sprintf('| %d | %s | %d | %s |', grp$G, grp$classification, grp$n, grp$starts))
  fl <- st[st$classification == 'POSSIBLE_PREMATURE_STOP', ]
  if (nrow(fl)) L <- c(L, '', '## POSSIBLE_PREMATURE_STOP starts', '',
    '| G | start | seed | stopped at iter | original log-lik | strict log-lik | gain | delta BIC at fixed G | added iters | param. move | final rel. change | Aitken remaining |', '|---|---|---|---|---|---|---|---|---|---|---|---|',
    sprintf('| %d | %d | %d | %d | %s | %s | %s | %s | %d | %s | %s | %s |', fl$G, fl$start, fl$seed, fl$original_iterations, f(fl$original_loglik), f(fl$strict_loglik), f(fl$gain), f(fl$delta_BIC_fixed_G),
            fl$additional_iterations, f(fl$aligned_param_move), e(fl$final_rel_change), e(fl$aitken_remaining)))
  bad <- st[!st$classification %in% c(CONFIRM_USABLE), ]
  if (nrow(bad)) L <- c(L, '', '## Starts not usable in the strict comparison', '', '| G | start | classification | reason |', '|---|---|---|---|',
                        sprintf('| %d | %d | %s | %s |', bad$G, bad$start, bad$classification, gsub('|', '/', bad$reason, fixed = TRUE)))
  L <- c(L, '', '## Thresholds (project heuristics, pending review; not statistical tests)', '', '| Name | Value | Type | Use |', '|---|---|---|---|',
         vapply(names(summ$thresholds), function(k) { t <- summ$thresholds[[k]]; sprintf('| %s | %s | %s | %s |', k, format(t$value), t$type, t$use) }, character(1)),
         '', 'Final relative change, Aitken estimate, next-step parameter change and parameter move are descriptive; none of them decides a classification.')
  enc2utf8(L)
}

confirm_cli <- function(argv) {
  keys <- c('stage4-dir', 'input', 'spec', 'output', 'g', 'strict-tol', 'strict-max-iter', 'config')
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
  miss <- setdiff(c('stage4-dir', 'input', 'spec', 'output'), names(a)); if (length(miss)) fail('Missing settings: ', paste(miss, collapse = ', '))
  num <- function(v, d) if (is.null(v)) d else { x <- suppressWarnings(as.numeric(v)); if (is.na(x)) fail('Invalid number: ', v); x }
  confirm_stage4(a[['stage4-dir']], a$input, a$spec, a$output, g = a$g, strict_tol = num(a[['strict-tol']], CONFIRM_DEFAULTS$strict_tol),
                 strict_max_iter = as.integer(num(a[['strict-max-iter']], CONFIRM_DEFAULTS$strict_max_iter)), config_file = a$config)
}

if (sys.nframe() == 0L) {
  r <- tryCatch(confirm_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
  t <- r$by_G
  print(format(data.frame(G = t$G, original = round(t$original_loglik, 4), strict = round(t$strict_loglik, 4), d_loglik = round(t$delta_loglik, 5), premature = t$n_possible_premature,
                          ORIGINAL_BEST_PREMATURE = t$ORIGINAL_BEST_PREMATURE, BETTER_OPTIMUM_HIDDEN = t$BETTER_OPTIMUM_HIDDEN)), row.names = FALSE)
  cat(sprintf('BIC preferred G: original %s, strict %s; AIC preferred G: original %s, strict %s\n', r$selection$original$BIC_G, r$selection$strict$BIC_G, r$selection$original$AIC_G, r$selection$strict$AIC_G))
  cat('Diagnostic only: no model was replaced. Output directory:', r$output_dir, '\n')
}
