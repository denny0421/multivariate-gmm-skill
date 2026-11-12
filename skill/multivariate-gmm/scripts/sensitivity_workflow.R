# Sensitivity analysis inside the workflow (sourced by workflow.R; it has no CLI of its own).
# It connects existing parts and adds no statistical rule:
#   stage4_select (fit), confirm_stage4 (diagnostic), wf_model_entry (registration), activate-model (the only way to switch).
# Two approvals: sensitivity-run --approved true covers the fit, the diagnostic and registering a valid fit as a candidate.
# Changing the active model always needs a separate activate-model --approved true.
#
# A plan's lifecycle (plan status) is separate from a command's Outcome (F7):
#   PLANNED > RUNNING > FIT_COMPLETED > [CONFIRMED] > CANDIDATE_REGISTERED | NO_NEW_CANDIDATE
#   RUNNING > BLOCKED (no valid model); any step > FAILED; closing > CLOSED_KEEP_ACTIVE | WITHDRAWN
# CONFIRMED means the diagnostic ran, not that it passed; with tol <= strict_tol it does not run and the status is skipped.
source(file.path(WF_DIR, 'confirm_stage4.R'), local = TRUE)

SENS_VERSION <- '0.2.0'
SENS_UNFINISHED <- c('RUNNING', 'FIT_COMPLETED', 'CONFIRMED') # the run started and has not reached an end state
SENS_OPEN <- c('PLANNED', SENS_UNFINISHED, 'FAILED')          # needs a command or decision before another plan may start
SENS_NOT_REPEATABLE_AFTER <- c('FAILED', 'WITHDRAWN')         # only these may be planned again with identical settings

# ---------------------------------------------------------------- shared checks
sens_is_legacy <- function(st) { raw <- jsonlite::fromJSON(file.path(st$root, WF_STATE), simplifyVector = FALSE); is.null(raw$models) && !is.null(raw$stages$stage4$selected_G) } # wf_read builds the registry only in memory
sens_writable <- function(st) {
  wf_require(!sens_is_legacy(st), 'This workflow was created before the model registry and is read-only for sensitivity analysis: only sensitivity-status is allowed. Its files were not changed.')
  wf_require(st$status %in% c('active', 'complete'), sprintf('Sensitivity analysis needs an active or complete workflow (status: %s).', st$status))
  wf_require(!is.null(st$active_model_id) && !is.null(st$models[[st$active_model_id]]), 'Sensitivity analysis needs an active model. If Stage 4 found no valid model, rerun stage4 with other numerical settings.')
  invisible(TRUE)
}
sens_is_open <- function(st, e) e$status %in% SENS_OPEN || (identical(e$status, 'CANDIDATE_REGISTERED') && identical(st$models[[e$candidate_model_id]]$status, 'candidate'))
sens_int <- function(v, name, min = -.Machine$integer.max) {
  x <- suppressWarnings(as.numeric(v))
  if (length(x) != 1L || !is.finite(x) || x != round(x) || x < min || abs(x) > .Machine$integer.max) fail(name, ' must be a whole number', if (min > -.Machine$integer.max) sprintf(' of at least %d', as.integer(min)) else '', ', received: ', v)
  as.integer(x)
}
sens_num_pos <- function(v, name) { x <- suppressWarnings(as.numeric(v)); if (length(x) != 1L || !is.finite(x) || x <= 0) fail(name, ' must be a positive number, received: ', v); x }
sens_dir_hashes <- function(d) { f <- sort(list.files(d, full.names = TRUE)); setNames(as.list(vapply(f, wf_hash, '', USE.NAMES = FALSE)), basename(f)) }
sens_check_hashes <- function(rec, d, what) {
  now <- unlist(sens_dir_hashes(d)); rec <- unlist(rec)
  if (!identical(now[order(names(now))], rec[order(names(rec))])) refuse('The ', what, ' output changed after it was recorded: ', d)
  invisible(TRUE)
}
sens_hist <- function(st, command, result) { st$history[[length(st$history) + 1L]] <- list(time = wf_now(), command = command, result = result); st } # never touches the gate
sens_set <- function(st, id, status = NULL, step = NULL, info = NULL) {
  e <- st$sensitivity$plans[[id]]
  if (!is.null(step) && !is.null(info)) e$steps[[step]] <- info
  if (!is.null(status)) { e$status <- status; e$lifecycle[[length(e$lifecycle) + 1L]] <- list(status = status, step = step, time = wf_now()) }
  st$sensitivity$plans[[id]] <- e
  st
}

# Everything a run depends on must still be what the plan recorded.
sens_verify_plan <- function(st, id) {
  e <- st$sensitivity$plans[[id]]
  if (is.null(e)) fail('Unknown sensitivity plan "', id, '". Known plans: ', paste(names(st$sensitivity$plans), collapse = ', '))
  f <- file.path(e$dir, 'plan.json')
  if (!file.exists(f)) refuse('Plan file is missing: ', f)
  if (!identical(wf_hash(f), e$plan_sha256)) refuse('Plan content changed after it was presented for approval: ', f)
  p <- jsonlite::fromJSON(f, simplifyVector = TRUE); a <- st$stages$stage3$approved
  if (!identical(p$plan_id, id)) refuse('Plan file does not belong to plan ', id, '.')
  if (!identical(p$active_model_id, st$active_model_id)) refuse(sprintf('The active model changed since this plan was made (plan: %s; now: %s). Withdraw it and create a new plan.', p$active_model_id, st$active_model_id))
  if (!identical(p$spec_hash, a$spec_hash) || !identical(p$approval_id, a$approval_id)) refuse('The Stage 3 approval differs from the one recorded in this plan.')
  if (!identical(wf_hash(a$spec), p$spec_sha256)) refuse('The Stage 3 spec file changed since this plan was made: ', a$spec)
  if (!identical(wf_hash(a$data), p$data_sha256)) refuse('The analysis data changed since this plan was made: ', a$data)
  sens_verify_init(p)
  sens_verify_g(a$spec, p$settings$g)
  wf_verify_model(st, st$models[[st$active_model_id]])
  list(plan = p, entry = e)
}
# The initialisation that runs must be the one the user approved, with the same recorded definition and random number generator.
# init_spec is absent only from plans written before F9, which always inherited the active model's method.
sens_verify_init <- function(p) {
  i <- p$settings$init
  if (length(i) != 1L || !i %in% EM_INIT_METHODS) refuse('The plan names an unsupported initialisation method: ', paste(i, collapse = ','))
  if (identical(i, 'ward') && p$settings$n_starts != 1) refuse('The plan uses init = ward with n_starts = ', p$settings$n_starts, '; Ward needs exactly one start.')
  if (is.null(p$init_spec)) return(invisible(TRUE))
  spec <- em_init_spec(i)
  if (!identical(p$init_spec[names(spec)], spec) || length(p$init_spec) != length(spec)) refuse(sprintf('The initialisation recorded in this plan (%s) does not match its approved definition.', i))
  if (!identical(p$rng_kind, em_rng_kind())) refuse(sprintf('The random number generator differs from the one recorded in this plan (plan: %s; now: %s), so the starts could not be reproduced.', p$rng_kind, em_rng_kind()))
  invisible(TRUE)
}
sens_verify_g <- function(spec, g) {
  Gc <- as.integer(jsonlite::fromJSON(spec, simplifyVector = TRUE)$G_candidates)
  if (!all(g %in% Gc)) refuse('G {', paste(setdiff(g, Gc), collapse = ','), '} is outside the approved Stage 3 candidates {', paste(Gc, collapse = ','), '}. Changing the candidates needs a new run and a new Stage 3 approval.')
  invisible(Gc)
}

# Thresholds stay as approved. A max_iter that reaches strict_max_iter is recorded, never adjusted.
sens_confirm_plan <- function(tol, max_iter) {
  s <- CONFIRM_DEFAULTS; run <- tol > s$strict_tol; conflict <- run && max_iter >= s$strict_max_iter
  list(status = if (run) 'WILL_RUN' else 'NOT_RUN', strict_tol = s$strict_tol, strict_max_iter = s$strict_max_iter,
       reason = if (run) sprintf('fit tol %g is above the approved strict_tol %g', tol, s$strict_tol)
                else sprintf('fit tol %g is already at or below the approved strict_tol %g, and the diagnostic only continues a fit under a tighter tolerance. NOT_RUN is not a passed confirmation.', tol, s$strict_tol),
       max_iter_conflict = conflict,
       conflict_note = if (conflict) sprintf('Plan max_iter %d reaches the approved strict_max_iter %d (total iterations per start). The approved value is kept: a start that used all %d iterations has none left and is reported as STRICT_NOT_CONVERGED, so it stays unconfirmed.', max_iter, s$strict_max_iter, s$strict_max_iter) else NULL)
}

# Reads the diagnostic's own results. Findings stay as warnings; nothing here can adopt a solution.
sens_confirm_summary <- function(r, cp, dir) {
  t <- r$by_G; prem <- t$G[t$ORIGINAL_BEST_PREMATURE %in% TRUE]; hid <- t$G[t$BETTER_OPTIMUM_HIDDEN %in% TRUE]; s <- r$starts
  no_budget <- sum(s$original_status == 'CONVERGED_VALID' & s$G > 1 & s$original_iterations >= cp$strict_max_iter, na.rm = TRUE)
  complete <- isTRUE(r$selection$all_valid_starts_confirmed)
  w <- c(if (length(prem)) sprintf('WARNING ORIGINAL_BEST_PREMATURE at G = %s: the best start gained at least the approved margin under the stricter tolerance.', paste(prem, collapse = ', ')),
         if (length(hid)) sprintf('WARNING BETTER_OPTIMUM_HIDDEN at G = %s: another start reached a better solution under the stricter tolerance.', paste(hid, collapse = ', ')),
         if (!complete) 'WARNING CONFIRMATION_INCOMPLETE: not every valid start could be confirmed; see confirmation_starts.csv.',
         if (no_budget > 0L) sprintf('WARNING STRICT_MAX_ITER_CONFLICT: %d start(s) had no iterations left under strict_max_iter %d.', no_budget, cp$strict_max_iter))
  list(status = 'RUN', result = if (length(prem) || length(hid)) 'WARNING' else if (!complete) 'INCOMPLETE' else 'NO_FLAGS', dir = dir,
       strict_tol = cp$strict_tol, strict_max_iter = cp$strict_max_iter, max_iter_conflict = isTRUE(cp$max_iter_conflict), conflict_note = cp$conflict_note, starts_without_budget = no_budget,
       ORIGINAL_BEST_PREMATURE_G = as.list(prem), BETTER_OPTIMUM_HIDDEN_G = as.list(hid), all_valid_starts_confirmed = complete,
       BIC_preference_changed = isTRUE(r$selection$BIC_preference_changed), AIC_preference_changed = isTRUE(r$selection$AIC_preference_changed),
       warnings = as.list(w), adopted = FALSE, note = 'Diagnostic only. Any better solution seen here is not adopted; replacing a model needs a new fit and a formal approval.', time = wf_now())
}

# ---------------------------------------------------------------- candidate validity
# Uses only existing rules: em_check (positive definite, conditioning, effective n), the Stage 5 tolerances and the approved replay_match_abs.
sens_validate_candidate <- function(st, dir, p) {
  a <- st$stages$stage3$approved; d <- s4_read_approved(a$data, a$spec); X <- d$X; storage.mode(X) <- 'double'; n <- nrow(X); pp <- ncol(X)
  bad <- function(...) fail('Candidate validation failed: ', ...)
  miss <- WF_MODEL_FILES[!file.exists(file.path(dir, WF_MODEL_FILES))]; if (length(miss)) bad('missing ', paste(miss, collapse = ', '))
  sj <- jsonlite::fromJSON(file.path(dir, 'selected_model.json'), simplifyVector = TRUE); rd <- readRDS(file.path(dir, 'selected_model.rds'))
  G <- as.integer(rd$G); par <- rd$par
  if (!identical(as.numeric(sj$selected_G), as.numeric(G))) bad('selected_model.json and selected_model.rds disagree on G.')
  if (!all(G %in% p$settings$g)) bad('selected G is outside this plan.')
  di <- read.csv(file.path(dir, 'convergence_diagnostics.csv'), stringsAsFactors = FALSE); di <- di[di$G == G, ]
  rc <- jsonlite::fromJSON(file.path(dir, 'run_config.json'), simplifyVector = TRUE)
  if (!identical(rc$init, p$settings$init)) bad('the fit used init = ', rc$init, ' but the plan approved ', p$settings$init, '.')
  if (G > 1L && (is.null(di$init_method) || any(di$init_method != p$settings$init))) bad('the starts do not record the approved initialisation ', p$settings$init, '.')
  if (!any(di$status == 'CONVERGED_VALID')) bad('no CONVERGED_VALID start at G = ', G, '.')
  bs <- di[di$start == sj$best_start, ]
  if (nrow(bs) != 1L || bs$status != 'CONVERGED_VALID') bad('the selected start ', sj$best_start, ' is not CONVERGED_VALID.')
  if (is.null(par) || length(par$pi) != G || !is.matrix(par$mu) || !identical(dim(par$mu), c(G, pp)) || length(par$Sigma) != G || length(par$Nk) != G || !all(vapply(par$Sigma, function(S) identical(dim(S), c(pp, pp)), NA))) bad('selected model parameters are incomplete.')
  chk <- em_check(par, pp, p$settings$min_effective_n, p$settings$max_cov_condition)
  if (!is.null(chk)) bad(chk$status, ': ', chk$reason)
  e <- em_estep(X, par); if (!isTRUE(e$ok)) bad(e$reason)
  if (abs(e$loglik - rd$loglik) > 1e-6 * (1 + abs(rd$loglik))) bad('stored log-likelihood is not reproduced by the stored parameters.')
  post <- read.csv(file.path(dir, 'posterior_selected.csv'), check.names = FALSE); tc <- paste0('tau_', seq_len(G))
  if (nrow(post) != n || !all(tc %in% names(post))) bad('posterior_selected.csv is incomplete (', nrow(post), ' rows; expected ', n, ').')
  tau <- as.matrix(post[, tc, drop = FALSE])
  if (any(!is.finite(tau)) || max(abs(rowSums(tau) - 1)) > S5_THRESHOLDS$posterior_reproduction$value) bad('posterior probabilities are not finite or do not sum to one.')
  if (!identical(as.character(post[[1L]]), as.character(rd$row_ids))) bad('posterior row IDs differ from the model.')
  d_post <- max(abs(tau - e$tau)); if (d_post > S5_THRESHOLDS$posterior_reproduction$value) bad(sprintf('posterior is not reproduced by the parameters (max diff %.3g).', d_post))
  sel <- s4_select(data.frame(G = G, n = n, p = pp, loglik = rd$loglik, eligible = TRUE), G)$table
  tol_eq <- CONFIRM_DEFAULTS$replay_match_abs; mc <- read.csv(file.path(dir, 'model_comparison.csv'), stringsAsFactors = FALSE); mc <- mc[mc$G == G, ]
  same <- function(a, b) length(a) == 1L && length(b) == 1L && is.finite(a) && is.finite(b) && abs(a - b) <= tol_eq
  for (src in list(list('selected_model.json', sj), list('model_comparison.csv', mc))) for (k in c('loglik', 'BIC', 'AIC', 'k_G')) if (!same(src[[2]][[k]], sel[[k]])) bad(k, ' in ', src[[1]], ' does not match the value computed from the model.')
  list(valid_starts_at_G = sum(di$status == 'CONVERGED_VALID'), posterior_max_diff = d_post, covariance_check = 'em_check passed', loglik_BIC_AIC_consistent = TRUE, time = wf_now())
}

# An exact match on estimates, because the file hash also changes with the recorded settings.
sens_same_model <- function(st, dir) {
  rd <- readRDS(file.path(dir, 'selected_model.rds'))
  for (m in st$models) { o <- readRDS(file.path(m$dir, 'selected_model.rds')); if (identical(o$par, rd$par) && identical(o$loglik, rd$loglik)) return(m$model_id) }
  NULL
}

# ---------------------------------------------------------------- comparison (descriptive; no threshold, no test, no recommendation)
sens_facts <- function(dir) {
  sj <- jsonlite::fromJSON(file.path(dir, 'selected_model.json'), simplifyVector = TRUE); rc <- jsonlite::fromJSON(file.path(dir, 'run_config.json'), simplifyVector = TRUE)
  mc <- read.csv(file.path(dir, 'model_comparison.csv'), stringsAsFactors = FALSE); r <- mc[mc$G == sj$selected_G, ]
  w <- as.character(r$diagnostic_warnings); if (is.na(w)) w <- ''
  di <- read.csv(file.path(dir, 'convergence_diagnostics.csv'), stringsAsFactors = FALSE)
  me <- di$min_cov_eigenvalue[di$G == sj$selected_G & di$start == sj$best_start]; if (!length(me)) me <- NA_real_ # the column does not exist in fits made before F9
  list(values = c(list(G = sj$selected_G, loglik = sj$loglik, BIC = sj$BIC, AIC = sj$AIC, k_G = sj$k_G, BIC_preferred_G = sj$selected_G, AIC_preferred_G = sj$aic_selected_G, tol = rc$tol, max_iter = rc$max_iter, n_starts = rc$n_starts, seed = rc$seed, init = rc$init,
                         best_start = sj$best_start), as.list(r[c('n_valid_starts', 'n_starts_reaching_best', 'n_distinct_optima', 'min_pi', 'min_effective_n', 'max_cov_condition')]), list(min_cov_eigenvalue = me), as.list(r[paste0('n_', tolower(EM_STATUSES))]), list(diagnostic_warnings = w)), per_G = mc)
}
SENS_LIKELIHOOD_LIMIT <- 'A higher log-likelihood alone does not make a model more reliable: the full-covariance Gaussian mixture likelihood is unbounded as a covariance collapses. Read it together with min_effective_n, max_cov_condition and min_cov_eigenvalue.'
sens_compare <- function(active, cand_dir, id, cand_id) {
  a <- sens_facts(active$dir); b <- sens_facts(cand_dir); val <- function(x) if (is.numeric(x)) format(x, digits = 15, trim = TRUE) else as.character(x)
  row <- function(metric, x, y) data.frame(metric = metric, active = if (length(x) && !is.na(x)) val(x) else '', candidate = if (length(y) && !is.na(y)) val(y) else '',
                                           difference = if (is.numeric(x) && is.numeric(y) && length(x) && length(y) && !is.na(x) && !is.na(y)) val(y - x) else '', stringsAsFactors = FALSE)
  tab <- do.call(rbind, lapply(names(a$values), function(k) row(k, a$values[[k]], b$values[[k]])))
  gs <- sort(union(a$per_G$G, b$per_G$G))
  get1 <- function(df, g, k) { v <- df[[k]][df$G == g]; if (length(v)) v else NA_real_ }
  per <- do.call(rbind, lapply(gs, function(g) do.call(rbind, lapply(c('loglik', 'BIC', 'AIC'), function(k) row(sprintf('G%d_%s', g, k), get1(a$per_G, g, k), get1(b$per_G, g, k))))))
  list(plan_id = id, active_model_id = active$model_id, candidate_model_id = cand_id, table = rbind(tab, per), note = paste('Descriptive comparison only: no threshold, significance test or recommendation is applied, and the lowest BIC never replaces the active model.', SENS_LIKELIHOOD_LIMIT))
}
sens_write_compare <- function(cmp, confirmation, out) {
  stage_and_commit(out, function(d) {
    write.csv(cmp$table, file.path(d, 'comparison.csv'), row.names = FALSE)
    write_json_file(c(cmp, list(confirmation = confirmation)), file.path(d, 'comparison.json'))
  }, function(d) if (!all(file.exists(file.path(d, c('comparison.csv', 'comparison.json'))))) fail('Staged comparison output is incomplete.'))
}
sens_compare_text <- function(cmp) { t <- cmp$table[!grepl('^G[0-9]+_', cmp$table$metric), ]; paste(c(sprintf('%-24s %-22s %-22s %s', 'metric', 'active', 'candidate', 'difference'), sprintf('%-24s %-22s %-22s %s', t$metric, t$active, t$candidate, t$difference)), collapse = '\n') }

# ---------------------------------------------------------------- commands
sens_settings_key <- function(s) sprintf('g=%s|n=%d|tol=%s|max=%d|seed=%d|init=%s', paste(s$g, collapse = ','), as.integer(s$n_starts), format(s$tol, digits = 15), as.integer(s$max_iter), as.integer(s$seed), s$init)
# Plans written before F9 have no init in their key; their plan file still says which method they used.
sens_entry_key <- function(e) if (grepl('|init=', e$settings_key, fixed = TRUE)) e$settings_key else paste0(e$settings_key, '|init=', jsonlite::fromJSON(file.path(e$dir, 'plan.json'), simplifyVector = TRUE)$settings$init)

sens_plan <- function(root, n_starts = NULL, tol = NULL, max_iter = NULL, seed = NULL, g = NULL, init = NULL) {
  st <- wf_read(root); sens_writable(st)
  open <- Filter(function(e) sens_is_open(st, e), st$sensitivity$plans)
  wf_require(!length(open), sprintf('Plan %s (%s) must be finished or closed first; see sensitivity-status.', names(open)[1L], open[[1L]]$status))
  m <- wf_use_active(st); a <- st$stages$stage3$approved; rc <- jsonlite::fromJSON(file.path(m$dir, 'run_config.json'), simplifyVector = TRUE)
  if (!is.null(init) && !init %in% EM_INIT_METHODS) fail('--init must be one of ', paste(EM_INIT_METHODS, collapse = ', '), ', received: ', init)
  cur <- list(g = as.integer(rc$g), n_starts = as.integer(rc$n_starts), tol = rc$tol, max_iter = as.integer(rc$max_iter), seed = as.integer(rc$seed), init = rc$init)
  new <- list(g = if (is.null(g)) cur$g else parse_g_em(g),
              n_starts = if (is.null(n_starts)) cur$n_starts else sens_int(n_starts, '--n-starts', 1),
              tol = if (is.null(tol)) cur$tol else sens_num_pos(tol, '--tol'),
              max_iter = if (is.null(max_iter)) cur$max_iter else sens_int(max_iter, '--max-iter', 1),
              seed = if (is.null(seed)) cur$seed else sens_int(seed, '--seed'),
              init = if (is.null(init)) cur$init else init)
  if (!length(new$g)) fail('--g selects no components.')
  if (new$seed > .Machine$integer.max - new$n_starts) fail('--seed is too large for this number of starts.')
  em_check_init(new$init, new$n_starts)
  sens_verify_g(a$spec, new$g)
  same_setting <- function(x, y) if (is.character(x)) identical(x, y) else identical(as.numeric(x), as.numeric(y))
  chg <- Filter(function(k) !same_setting(cur[[k]], new[[k]]), names(new))
  wf_require(length(chg) > 0L, 'These settings are identical to the active model; there is nothing to test.')
  key <- sens_settings_key(new)
  dup <- Filter(function(e) identical(sens_entry_key(e), key) && !e$status %in% SENS_NOT_REPEATABLE_AFTER, st$sensitivity$plans)
  wf_require(!length(dup), sprintf('Plan %s already covers exactly these settings (status %s).', names(dup)[1L], dup[[1L]]$status))
  settings <- c(new, list(min_effective_n = rc$min_effective_n, max_cov_condition = rc$max_cov_condition))
  init_changed <- 'init' %in% chg
  init_note <- c(if (init_changed) sprintf('The active model used init = %s, so its iteration count may not describe init = %s.', cur$init, new$init),
                 if (new$init %in% EM_RANDOM_INITS) 'Random starts can spread over many local optima and usually need more iterations per start than k-means; with few starts the best one can be worse. The number of starts is never raised automatically.')
  obs <- read.csv(file.path(m$dir, 'convergence_diagnostics.csv'), stringsAsFactors = FALSE); obs <- obs[obs$G > 1 & obs$status == 'CONVERGED_VALID', ]
  mean_it <- if (nrow(obs)) mean(obs$iterations) else NA_real_; em_solves <- new$n_starts * sum(new$g > 1L); closed <- sum(new$g == 1L)
  work <- list(em_solves = em_solves, closed_form_fits = closed, iteration_upper_bound = em_solves * new$max_iter, active_mean_iterations = mean_it, indicative_iterations = if (is.na(mean_it)) NA_real_ else em_solves * mean_it,
               note = paste(c('Indicative only: based on the active model\'s iterations; a tighter tol usually needs more. The convergence confirmation replays and continues every valid start in addition. No time estimate is given.', init_note), collapse = ' '))
  cp <- sens_confirm_plan(new$tol, new$max_iter)
  parent <- file.path(st$root, 'sensitivity'); dir.create(parent, showWarnings = FALSE)
  stamp <- format(Sys.time(), '%Y%m%d-%H%M%S', tz = 'UTC'); k <- 1L
  repeat { id <- sprintf('S-%s-%02d', stamp, k); d <- file.path(parent, id); if (dir.create(d, showWarnings = FALSE)) break; k <- k + 1L }
  diff <- lapply(chg, function(k) list(setting = k, active = I(cur[[k]]), plan = I(new[[k]])))
  plan <- list(record_type = 'sensitivity_plan', script_version = SENS_VERSION, plan_id = id, created_utc = wf_now(), active_model_id = m$model_id, spec_hash = a$spec_hash, approval_id = a$approval_id, spec_sha256 = wf_hash(a$spec), data_sha256 = wf_hash(a$data),
               settings = list(g = I(new$g), n_starts = new$n_starts, tol = new$tol, max_iter = new$max_iter, seed = new$seed, init = settings$init, min_effective_n = settings$min_effective_n, max_cov_condition = settings$max_cov_condition),
               init_spec = em_init_spec(new$init), rng_kind = em_rng_kind(), start_seeds = sprintf('start s uses seed %d + s - 1', new$seed),
               differences = diff, workload = work, confirmation = cp, likelihood_limitation = SENS_LIKELIHOOD_LIMIT,
               approval_scope = 'Approving this plan covers the fit, the diagnostic confirmation and registering a valid fit as a candidate. It does not change the active model.')
  f <- file.path(d, 'plan.json'); write_json_file(plan, f)
  st$sensitivity$plans[[id]] <- list(plan_id = id, status = 'PLANNED', dir = d, plan_sha256 = wf_hash(f), settings_key = key, active_model_id = m$model_id, created_utc = wf_now(), steps = list(), lifecycle = list(list(status = 'PLANNED', step = 'plan', time = wf_now())))
  st <- wf_gate(wf_log(st, 'sensitivity-plan', id), 'AWAITING_USER_APPROVAL', 'sensitivity-plan', 'SENSITIVITY_PLAN_APPROVAL', sprintf('Plan %s needs the user\'s approval before anything is fitted.', id),
                list(sprintf('sensitivity-run --plan %s --approval-ref "..." --approved true', id), sprintf('sensitivity-close --plan %s --decision withdraw --approval-ref "..." --approved true', id)))
  wf_write(st)
  txt <- c(sprintf('Plan %s. Active model %s stays active.', id, m$model_id),
           vapply(chg, function(k) sprintf('  changed %s: %s -> %s', k, paste(format(cur[[k]], digits = 15, trim = TRUE), collapse = ','), paste(format(new[[k]], digits = 15, trim = TRUE), collapse = ',')), ''),
           sprintf('Initialisation: active model %s; this plan %s%s.', cur$init, new$init, if (init_changed) ' (CHANGED)' else ' (unchanged)'),
           sprintf('  %s', em_init_detail(new$init)),
           sprintf('  random number generator: %s; start s uses seed %d + s - 1', em_rng_kind(), new$seed),
           sprintf('  unchanged %smin_effective_n: %s; max_cov_condition: %s', if (init_changed) '' else sprintf('init: %s; ', settings$init), settings$min_effective_n, format(settings$max_cov_condition)),
           sprintf('Workload: %d EM solves + %d closed-form fit(s); iteration upper bound %s; indicative %s (active mean %s per start).', em_solves, closed, format(work$iteration_upper_bound, big.mark = ',', scientific = FALSE), if (is.na(mean_it)) 'not available' else format(round(work$indicative_iterations), big.mark = ',', scientific = FALSE), if (is.na(mean_it)) 'n/a' else sprintf('%.1f', mean_it)), work$note,
           sprintf('Convergence confirmation: %s (%s).', cp$status, cp$reason), if (isTRUE(cp$max_iter_conflict)) paste('WARNING:', cp$conflict_note), SENS_LIKELIHOOD_LIMIT, plan$approval_scope)
  list(status = 'AWAITING_APPROVAL', message = paste(txt, collapse = '\n'), next_action = wf_next(st), output = d, plan_id = id)
}

sens_run <- function(root, plan_id, approval_ref = NULL, approved = FALSE, hooks = list()) {
  st <- wf_read(root); sens_writable(st)
  if (!isTRUE(approved)) refuse('A sensitivity run requires the user\'s explicit approval of this plan: pass --approved true only after the user approved it.')
  if (is.null(approval_ref) || !nzchar(trimws(approval_ref))) refuse('A sensitivity run needs --approval-ref (the user\'s approval of this plan).')
  if (is.null(plan_id)) fail('--plan is required.')
  v <- sens_verify_plan(st, plan_id); p <- v$plan; pd <- v$entry$dir
  wf_require(identical(v$entry$status, 'PLANNED'), sprintf('Plan %s has status %s and cannot be run; approval cannot change that. See sensitivity-status.', plan_id, v$entry$status))
  fit_dir <- file.path(pd, 'fit'); conf_dir <- file.path(pd, 'confirmation'); cmp_dir <- file.path(pd, 'comparison')
  wf_require(!any(dir.exists(c(fit_dir, conf_dir, cmp_dir))), sprintf('Plan %s already has output folders; earlier output is never reused.', plan_id))
  a <- st$stages$stage3$approved; s <- p$settings
  fit_fun <- if (is.null(hooks$fit_fun)) stage4_select else hooks$fit_fun
  confirm_fun <- if (is.null(hooks$confirm_fun)) confirm_stage4 else hooks$confirm_fun
  write <- if (is.null(hooks$write)) wf_write else hooks$write
  point <- function(name) if (!is.null(hooks[[name]])) hooks[[name]]()
  step <- 'start'
  tryCatch({
    st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = sprintf('sensitivity plan %s approved: fit, diagnostic confirmation, candidate registration; not activation', plan_id), ref = approval_ref)
    e <- st$sensitivity$plans[[plan_id]]; e$approval <- list(ref = approval_ref, time = wf_now()); st$sensitivity$plans[[plan_id]] <- e
    st <- sens_hist(sens_set(st, plan_id, 'RUNNING', 'fit'), 'sensitivity-run', paste('started', plan_id))
    st <- wf_gate(st, 'AWAITING_USER_APPROVAL', 'sensitivity-run', 'SENSITIVITY_RUN_UNFINISHED', sprintf('Plan %s has started and has not finished; if no process is running, it was interrupted.', plan_id),
                  list(sprintf('sensitivity-close --plan %s --decision withdraw --approval-ref "..." --approved true, then a new sensitivity-plan', plan_id)))
    st <- write(st); point('after_running')

    step <- 'fit'
    r <- fit_fun(a$data, a$spec, fit_dir, g = paste(s$g, collapse = ','), n_starts = as.integer(s$n_starts), seed = as.integer(s$seed), tol = s$tol, max_iter = as.integer(s$max_iter), init = s$init, min_effective_n = s$min_effective_n, max_cov_condition = s$max_cov_condition)
    point('after_fit_output')
    info <- list(status = r$selection$status, selected_G = r$selection$selected_G, dir = fit_dir, files = sens_dir_hashes(fit_dir), time = wf_now())
    if (is.na(r$selection$selected_G)) {
      st <- sens_hist(sens_set(st, plan_id, 'BLOCKED', 'fit', info), 'sensitivity-run', paste(plan_id, 'STOP_NO_VALID_MODELS'))
      st <- wf_gate(st, 'BLOCKED', 'sensitivity-run', 'STOP_NO_VALID_MODELS', 'No candidate G has a valid converged fit under this plan. Nothing was registered and the active model is unchanged.',
                    list('Review the fit outputs, then create a new sensitivity-plan with other numerical settings.', 'Changing the candidate G needs a new run and a new Stage 3 approval.'))
      st <- write(st)
      return(list(status = 'STOP_NO_VALID_MODELS', message = sprintf('No valid model under plan %s. Nothing was registered; active model %s is unchanged.', plan_id, st$active_model_id), next_action = wf_next(st), output = pd))
    }
    st <- write(sens_hist(sens_set(st, plan_id, 'FIT_COMPLETED', 'fit', info), 'sensitivity-run', paste(plan_id, 'fit completed'))); point('after_fit_state')

    step <- 'confirmation'; cp <- p$confirmation
    if (identical(cp$status, 'WILL_RUN')) {
      sens_check_hashes(info$files, fit_dir, 'fit')
      cr <- confirm_fun(fit_dir, a$data, a$spec, conf_dir, strict_tol = cp$strict_tol, strict_max_iter = as.integer(cp$strict_max_iter))
      point('after_confirm_output')
      conf <- sens_confirm_summary(cr, cp, conf_dir)
      st <- write(sens_hist(sens_set(st, plan_id, 'CONFIRMED', 'confirmation', conf), 'sensitivity-run', paste(plan_id, 'confirmation', conf$result))); point('after_confirm_state')
    } else {
      conf <- list(status = 'NOT_RUN', result = 'NOT_RUN', reason = cp$reason, confirmed = FALSE, warnings = list(paste('WARNING CONFIRMATION_NOT_RUN:', cp$reason)), time = wf_now())
      st <- write(sens_hist(sens_set(st, plan_id, NULL, 'confirmation', conf), 'sensitivity-run', paste(plan_id, 'confirmation NOT_RUN'))); point('after_confirm_state')
    }

    step <- 'comparison'
    cand_id <- sprintf('G%d-%s', as.integer(r$selection$selected_G), substr(wf_hash(file.path(fit_dir, 'selected_model.rds')), 1, 12))
    active <- st$models[[st$active_model_id]]; cmp <- sens_compare(active, fit_dir, plan_id, cand_id)
    sens_write_compare(cmp, conf, cmp_dir)
    st <- write(sens_set(st, plan_id, NULL, 'comparison', list(dir = cmp_dir, time = wf_now()))); point('after_comparison')

    step <- 'candidate_validation'
    sens_check_hashes(info$files, fit_dir, 'fit'); wf_verify_model(st, active)
    val <- sens_validate_candidate(st, fit_dir, p)
    m <- wf_model_entry(st, fit_dir, 'registered')
    fw <- jsonlite::fromJSON(file.path(fit_dir, 'selected_model.json'), simplifyVector = TRUE)$diagnostic_warnings
    warn <- c(if (length(fw)) paste('MODEL', fw), unlist(conf$warnings))
    point('before_register_state')

    step <- 'registration'
    same <- sens_same_model(st, fit_dir)
    if (!is.null(same)) {
      st <- sens_set(st, plan_id, 'NO_NEW_CANDIDATE', 'registration', list(status = 'NOT_REGISTERED', existing_model_id = same, validation = val, time = wf_now()))
      st <- wf_log(st, 'sensitivity-run', paste(plan_id, 'NO_NEW_CANDIDATE', same))
      st <- wf_gate(st, 'SUCCESS', 'sensitivity-run', 'NO_NEW_CANDIDATE', sprintf('The selected model has the same parameters and log-likelihood as registered model %s; nothing new was registered.', same))
      st <- write(st)
      return(list(status = 'NO_NEW_CANDIDATE', message = paste(c(sprintf('The selected model has the same parameters and log-likelihood as registered model %s. Nothing new was registered and the active model is unchanged.', same), sens_compare_text(cmp), warn), collapse = '\n'), next_action = wf_next(st), output = pd))
    }
    m$status <- 'candidate'; m$sensitivity <- list(plan_id = plan_id, plan_sha256 = v$entry$plan_sha256, confirmation = conf, validation = val, warnings = as.list(warn))
    st <- wf_store_model(st, m)
    st <- sens_set(st, plan_id, 'CANDIDATE_REGISTERED', 'registration', list(status = 'REGISTERED', model_id = m$model_id, validation = val, time = wf_now()))
    e <- st$sensitivity$plans[[plan_id]]; e$candidate_model_id <- m$model_id; st$sensitivity$plans[[plan_id]] <- e
    st <- wf_log(st, 'sensitivity-run', paste(plan_id, 'candidate', m$model_id))
    st <- wf_gate(st, 'AWAITING_USER_APPROVAL', 'sensitivity-run', 'ACTIVE_MODEL_DECISION', sprintf('Candidate %s is registered. The user decides whether to switch; active model %s is unchanged.', m$model_id, st$active_model_id),
                  list(sprintf('activate-model --model-id %s --approved true', m$model_id), sprintf('sensitivity-close --plan %s --decision keep-active --approval-ref "..." --approved true', plan_id)))
    st <- write(st)
    list(status = 'CANDIDATE_REGISTERED', message = paste(c(sprintf('Candidate %s registered; active model %s is unchanged. Confirmation: %s.', m$model_id, st$active_model_id, conf$result), sens_compare_text(cmp), cmp$note, warn), collapse = '\n'), next_action = wf_next(st), output = pd, model_id = m$model_id)
  }, error = function(err) {
    note <- tryCatch({
      s2 <- sens_set(wf_read(root), plan_id, 'FAILED', step, list(status = 'FAILED', error = conditionMessage(err), time = wf_now()))
      s2 <- wf_gate(sens_hist(s2, 'sensitivity-run', paste(plan_id, 'FAILED at', step)), 'AWAITING_USER_APPROVAL', 'sensitivity-run', 'SENSITIVITY_RUN_FAILED', sprintf('Plan %s failed at step %s. Completed outputs are kept and nothing further was registered.', plan_id, step),
                    list(sprintf('sensitivity-close --plan %s --decision withdraw --approval-ref "..." --approved true, then a new sensitivity-plan', plan_id)))
      write(s2); sprintf(' [Plan %s is FAILED at step %s; completed outputs are kept.]', plan_id, step)
    }, error = function(e2) sprintf(' [Plan %s failed at step %s, and its FAILED status could not be recorded: %s]', plan_id, step, conditionMessage(e2)))
    err$message <- paste0(conditionMessage(err), note)
    stop(err)
  })
}

sens_close <- function(root, plan_id, decision, approval_ref = NULL, approved = FALSE) {
  st <- wf_read(root); sens_writable(st)
  if (is.null(plan_id)) fail('--plan is required.')
  if (is.null(decision) || !decision %in% c('keep-active', 'withdraw')) fail('--decision must be keep-active or withdraw.')
  if (!isTRUE(approved)) refuse('Closing a plan requires the user\'s decision: pass --approved true only after the user made it.')
  if (is.null(approval_ref) || !nzchar(trimws(approval_ref))) refuse('Closing a plan needs --approval-ref (the user\'s decision).')
  e <- st$sensitivity$plans[[plan_id]]
  if (is.null(e)) fail('Unknown sensitivity plan "', plan_id, '".')
  pending <- identical(e$status, 'CANDIDATE_REGISTERED') && sens_is_open(st, e)
  if (identical(decision, 'keep-active')) {
    wf_require(pending, sprintf('keep-active applies to a registered candidate awaiting a decision (plan %s has status %s).', plan_id, e$status))
  } else {
    wf_require(e$status %in% c(SENS_OPEN, 'BLOCKED'), if (pending) 'This plan has a registered candidate: use --decision keep-active.' else sprintf('Plan %s has status %s and is already closed.', plan_id, e$status))
  }
  new <- if (identical(decision, 'keep-active')) 'CLOSED_KEEP_ACTIVE' else 'WITHDRAWN'; prev <- e$status
  st <- sens_set(st, plan_id, new, 'close', list(decision = decision, status_before = prev, ref = approval_ref, time = wf_now()))
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = sprintf('sensitivity plan %s closed: %s', plan_id, decision), ref = approval_ref)
  code <- if (identical(decision, 'keep-active')) 'SENSITIVITY_KEEP_ACTIVE' else 'SENSITIVITY_WITHDRAWN'
  st <- wf_gate(wf_log(st, 'sensitivity-close', paste(plan_id, decision)), 'SUCCESS', 'sensitivity-close', code, sprintf('Plan %s closed (%s); its files are kept.', plan_id, decision)); wf_write(st)
  list(status = code, message = sprintf('Plan %s closed (%s, previously %s). All files%s are kept; active model %s is unchanged.', plan_id, decision, prev, if (!is.null(e$candidate_model_id)) sprintf(' and candidate %s', e$candidate_model_id) else '', st$active_model_id), next_action = wf_next(st))
}

sens_confirm_convergence <- function(root, model_id = NULL, approved = FALSE, confirm_fun = confirm_stage4) {
  st <- wf_read(root); sens_writable(st)
  if (!isTRUE(approved)) refuse('Convergence confirmation re-executes EM: list its settings to the user and pass --approved true only after explicit approval.')
  id <- if (is.null(model_id)) st$active_model_id else model_id
  m <- st$models[[id]]; if (is.null(m)) fail('Unknown model id "', id, '". Registered: ', paste(names(st$models), collapse = ', '))
  wf_verify_model(st, m); a <- st$stages$stage3$approved
  cp <- sens_confirm_plan(m$settings$tol, m$settings$max_iter)
  if (identical(cp$status, 'NOT_RUN')) return(list(status = 'CONFIRMATION_NOT_RUN', message = sprintf('Model %s: confirmation NOT_RUN. %s', id, cp$reason), next_action = wf_next(st)))
  parent <- file.path(st$root, 'convergence-confirmation'); dir.create(parent, showWarnings = FALSE)
  stamp <- format(Sys.time(), '%Y%m%d-%H%M%S', tz = 'UTC'); k <- 1L
  repeat { cid <- sprintf('C-%s-%02d', stamp, k); d <- file.path(parent, cid); if (!dir.exists(d)) break; k <- k + 1L }
  cr <- confirm_fun(m$dir, a$data, a$spec, d, strict_tol = cp$strict_tol, strict_max_iter = as.integer(cp$strict_max_iter))
  conf <- sens_confirm_summary(cr, cp, d); conf$model_id <- id
  st$sensitivity$confirmations[[cid]] <- conf
  st$approvals[[length(st$approvals) + 1L]] <- list(time = wf_now(), item = sprintf('convergence confirmation approved for model %s', id))
  st <- sens_hist(st, 'confirm-convergence', paste(cid, id, conf$result)); wf_write(st) # a diagnostic does not replace a pending decision in the gate
  flagged <- length(conf$ORIGINAL_BEST_PREMATURE_G) || length(conf$BETTER_OPTIMUM_HIDDEN_G)
  code <- if (flagged) 'BETTER_SOLUTION_INDICATED' else if (identical(conf$result, 'INCOMPLETE')) 'CONFIRMATION_INCOMPLETE' else 'NO_FLAGS'
  list(status = code, message = paste(c(sprintf('Confirmation of model %s: %s. %s', id, conf$result, conf$note), unlist(conf$warnings)), collapse = '\n'), output = d,
       next_action = if (flagged) 'The model was not replaced. To test a better solution, create a new sensitivity-plan and let the user approve it.' else wf_next(st))
}

sens_plan_line <- function(st, e) {
  disk <- c('fit', 'confirmation', 'comparison'); disk <- disk[dir.exists(file.path(e$dir, disk))]; unrec <- setdiff(disk, names(e$steps))
  s <- tryCatch(jsonlite::fromJSON(file.path(e$dir, 'plan.json'), simplifyVector = TRUE)$settings, error = function(x) NULL)
  cf <- e$steps$confirmation
  paste0(sprintf('%s [%s]', e$plan_id, e$status),
         if (e$status %in% SENS_UNFINISHED) ' NOT FINISHED (running, or interrupted if no process is running)' else '',
         if (!is.null(s)) sprintf(' g=%s starts=%s tol=%s max_iter=%s seed=%s init=%s', paste(s$g, collapse = ','), s$n_starts, format(s$tol), s$max_iter, s$seed, s$init) else ' (plan file unreadable)',
         sprintf('; steps recorded: %s', if (length(e$steps)) paste(names(e$steps), collapse = ', ') else 'none'),
         if (length(unrec)) sprintf('; on disk but NOT recorded: %s', paste(unrec, collapse = ', ')) else '',
         if (!is.null(cf)) sprintf('; confirmation: %s', cf$result) else '',
         if (!is.null(e$candidate_model_id)) sprintf('; candidate %s (%s)', e$candidate_model_id, st$models[[e$candidate_model_id]]$status) else '',
         if (identical(e$status, 'FAILED')) { k <- e$lifecycle[[length(e$lifecycle)]]$step; sprintf('; failed at %s: %s', k, e$steps[[k]]$error) } else '')
}

sens_status <- function(root) {
  st <- wf_read(root); L <- character()
  if (sens_is_legacy(st)) L <- c(L, 'Older workflow (no registry on disk): read-only for sensitivity analysis. Nothing was changed.')
  if (is.null(st$active_model_id)) L <- c(L, 'No active model.')
  else {
    m <- st$models[[st$active_model_id]]; s <- m$settings
    L <- c(L, sprintf('Active model %s: G=%s loglik=%.4f BIC=%.3f AIC=%.3f', m$model_id, m$G, m$loglik, m$BIC, m$AIC),
           sprintf('  settings: tol=%s max_iter=%s n_starts=%s seed=%s init=%s; best start %s (seed %s)', format(s$tol), s$max_iter, s$n_starts, s$seed, s$init, s$best_start, s$best_start_seed))
    di <- read.csv(file.path(m$dir, 'convergence_diagnostics.csv'), stringsAsFactors = FALSE); tb <- table(di$status)
    L <- c(L, sprintf('  start status counts: %s', paste(names(tb), tb, sep = '=', collapse = ', ')))
    w <- jsonlite::fromJSON(file.path(m$dir, 'selected_model.json'), simplifyVector = TRUE)$diagnostic_warnings
    L <- c(L, if (length(w)) paste0('  model warning: ', w) else '  model warnings: none')
    cands <- Filter(function(x) identical(x$status, 'candidate'), st$models)
    L <- c(L, if (length(cands)) vapply(cands, function(x) sprintf('Candidate %s: G=%s loglik=%.4f BIC=%.3f AIC=%.3f', x$model_id, x$G, x$loglik, x$BIC, x$AIC), '', USE.NAMES = FALSE) else 'Candidates: none')
  }
  pl <- st$sensitivity$plans
  L <- c(L, if (length(pl)) vapply(pl, function(e) paste('Plan', sens_plan_line(st, e)), '', USE.NAMES = FALSE) else 'Sensitivity plans: none')
  cf <- st$sensitivity$confirmations
  if (length(cf)) L <- c(L, unlist(lapply(names(cf), function(k) c(sprintf('Confirmation %s of %s: %s', k, cf[[k]]$model_id, cf[[k]]$result), paste0('  ', unlist(cf[[k]]$warnings))))))
  list(status = 'OK', message = paste(L, collapse = '\n'), next_action = wf_next(st))
}

# What the plans are waiting for, or NULL. Derived from the plan records so that it stays correct whatever the last gate was.
wf_sens_next <- function(st) {
  pl <- st$sensitivity$plans; if (!length(pl)) return(NULL)
  for (e in rev(pl)) {
    id <- e$plan_id
    if (identical(e$status, 'PLANNED')) return(sprintf('USER APPROVAL: sensitivity-run --plan %s --approval-ref "..." --approved true, or sensitivity-close --plan %s --decision withdraw', id, id))
    if (e$status %in% SENS_UNFINISHED) return(sprintf('Plan %s has status %s and did not finish (if no process is running, it was interrupted). Completed outputs are kept. Use sensitivity-close --plan %s --decision withdraw, then a new sensitivity-plan.', id, e$status, id))
    if (identical(e$status, 'FAILED')) return(sprintf('Plan %s FAILED. Completed outputs are kept. Use sensitivity-close --plan %s --decision withdraw, then a new sensitivity-plan.', id, id))
    if (identical(e$status, 'CANDIDATE_REGISTERED') && sens_is_open(st, e)) return(sprintf('USER DECISION: activate-model --model-id %s --approved true, or sensitivity-close --plan %s --decision keep-active', e$candidate_model_id, id))
  }
  NULL
}
