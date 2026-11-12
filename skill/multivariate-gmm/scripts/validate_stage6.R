#!/usr/bin/env Rscript
# Stage 6 - Validation and profiling (generic: any p, any G, any external label values).
#   6A stability (multi-start; saved Stage 4 diagnostics; optional partition-level replay with the SAME approved seeds)
#   6B model sensitivity (selected G vs an alternative G, both evaluated from saved Stage 4 parameters - no refit)
#   6C external validation (labels read only here; ARI, NMI, cross-tables; optional matched agreement)
#   6D profiling (Stage 5 parameters + post-hoc label composition), optional descriptive strata check
# The external label never enters estimation or model selection.
suppressPackageStartupMessages(library(jsonlite))

s6_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
S6_SCRIPT_DIR <- dirname(s6_script_path())
source(file.path(S6_SCRIPT_DIR, 'interpret_stage5.R'), local = TRUE) # em_estep, s5_uncertainty, s4_like_read, staging utils

S6_VERSION <- '0.2.0'
S6_THRESHOLDS <- list(
  ari = list(formula = 'Hubert-Arabie adjusted Rand index; label-invariant; 1 = identical partitions, ~0 = chance agreement', type = 'exact'),
  nmi = list(formula = 'NMI = 2 I(U;V) / (H(U) + H(V)) (arithmetic normalisation); 1 = identical, 0 = independent', type = 'exact'),
  trivial_partitions = list(value = 'ARI = NMI = 1 if both partitions have one cluster; NMI = 0 if exactly one is trivial', type = 'convention'),
  split_share = list(value = 0.10, type = 'heuristic', use = 'an alternative-model component counts as a child of a selected-model component if it takes >= 10% of that component'),
  split_purity = list(value = 0.80, type = 'heuristic', use = '... and >= 80% of the child component comes from that parent'),
  reproduction = list(value = 1e-8, type = 'numerical tolerance', use = 'relative log-likelihood agreement when re-evaluating saved parameters or replaying starts'),
  matched_agreement = list(value = 'optimal one-to-one matching of components to labels (exhaustive search, max(G, K) <= 8)', type = 'descriptive',
                           use = 'reported separately from ARI/NMI; unmatched components count as disagreement'))

# ---------------------------------------------------------------- agreement indices (pure; unit-tested)
s6_ari <- function(a, b) {
  if (length(a) != length(b)) stop('Partitions must have equal length.', call. = FALSE)
  tab <- table(a, b); n <- sum(tab); c2 <- function(x) x * (x - 1) / 2
  sij <- sum(c2(tab)); sa <- sum(c2(rowSums(tab))); sb <- sum(c2(colSums(tab))); e <- sa * sb / c2(n); mx <- (sa + sb) / 2
  if (isTRUE(all.equal(mx, e))) return(if (nrow(tab) == 1 && ncol(tab) == 1) 1 else 0)
  (sij - e) / (mx - e)
}
s6_entropy <- function(p) { p <- p[p > 0]; -sum(p * log(p)) }
s6_nmi <- function(a, b) {
  if (length(a) != length(b)) stop('Partitions must have equal length.', call. = FALSE)
  P <- table(a, b) / length(a); pa <- rowSums(P); pb <- colSums(P)
  ha <- s6_entropy(pa); hb <- s6_entropy(pb)
  if (ha + hb == 0) return(1)
  nz <- P > 0; I <- sum(P[nz] * log(P[nz] / outer(pa, pb)[nz]))
  max(0, min(1, 2 * I / (ha + hb)))
}
s6_perms <- function(v) if (length(v) <= 1) list(v) else do.call(c, lapply(seq_along(v), function(i) lapply(s6_perms(v[-i]), function(r) c(v[i], r))))
# Optimal one-to-one matching between rows (components) and columns (labels) maximising matched counts.
s6_matched_agreement <- function(tab) {
  r <- nrow(tab); k <- ncol(tab); m <- max(r, k)
  if (m > 8) return(list(agreement = NA_real_, mapping = NULL, note = 'skipped: more than 8 components or labels'))
  M <- matrix(0, m, m); M[seq_len(r), seq_len(k)] <- tab
  best <- -1; bp <- NULL
  for (pp in s6_perms(seq_len(m))) { s <- sum(M[cbind(seq_len(m), pp)]); if (s > best) { best <- s; bp <- pp } }
  map <- data.frame(component = rownames(tab), matched_label = ifelse(bp[seq_len(r)] <= k, colnames(tab)[pmin(bp[seq_len(r)], k)], NA_character_),
                    matched_count = M[cbind(seq_len(r), bp[seq_len(r)])], component_size = rowSums(tab), stringsAsFactors = FALSE)
  list(agreement = best / sum(tab), mapping = map, note = 'post-hoc optimal one-to-one matching; not a training label assignment')
}

# Structural relation between two partitions with different numbers of components (no forced 1:1 pairing).
s6_split_analysis <- function(sel, alt, share = S6_THRESHOLDS$split_share$value, purity = S6_THRESHOLDS$split_purity$value) {
  T <- table(selected = sel, alternative = alt)
  colp <- sweep(T, 2, colSums(T), '/'); rowp <- sweep(T, 1, rowSums(T), '/')
  parent <- apply(T, 2, which.max); pur <- apply(colp, 2, max)
  alt_tab <- data.frame(alternative_component = colnames(T), size = as.integer(colSums(T)), main_parent = rownames(T)[parent],
                        purity = as.numeric(pur), stringsAsFactors = FALSE)
  events <- character()
  for (i in seq_len(nrow(T))) {
    kids <- which(rowp[i, ] >= share & parent == i & pur >= purity)
    if (length(kids) >= 2) events <- c(events, sprintf('SPLIT: selected component %s (n = %d) is divided into alternative components %s (%s of its members).',
                                                         rownames(T)[i], sum(T[i, ]), paste(colnames(T)[kids], collapse = ' + '),
                                                         paste(sprintf('%.0f%%', 100 * rowp[i, kids]), collapse = ' + ')))
  }
  mixed <- which(pur < purity)
  for (j in mixed) events <- c(events, sprintf('MIXED: alternative component %s (n = %d) draws from several selected components (%s).', colnames(T)[j], sum(T[, j]),
                                               paste(sprintf('%s: %.0f%%', rownames(T), 100 * colp[, j])[colp[, j] > 0], collapse = ', ')))
  one2one <- which(pur >= purity & vapply(seq_len(ncol(T)), function(j) rowp[parent[j], j] >= 1 - share, logical(1)))
  for (j in one2one) events <- c(events, sprintf('KEPT: alternative component %s corresponds to selected component %s (%.0f%% of it; purity %.0f%%).',
                                                 colnames(T)[j], rownames(T)[parent[j]], 100 * rowp[parent[j], j], 100 * pur[j]))
  list(table = T, alternative = alt_tab, events = if (length(events)) events else 'No split detected under the recorded thresholds.')
}

# ---------------------------------------------------------------- inputs
s6_par_from_json <- function(m, feats) {
  G <- m$G; p <- length(feats)
  mu <- matrix(unlist(lapply(m$mu, function(r) unlist(r)[feats])), G, p, byrow = TRUE, dimnames = list(NULL, feats))
  Sig <- lapply(seq_len(G), function(i) { S <- matrix(unlist(m$Sigma[[i]]), p, p, byrow = TRUE); S <- (S + t(S)) / 2; dimnames(S) <- list(feats, feats); S })
  list(pi = unlist(m$pi), mu = mu, Sigma = Sig, Nk = unlist(m$effective_n))
}
s6_read_labels <- function(labels, label_column, ids, idn) {
  lp <- resolve_path(labels); if (!file.exists(lp)) fail('External label file not found: ', lp)
  L <- read.csv(lp, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c('NA', ''))
  if (!idn %in% names(L)) fail('External label file has no "', idn, '" column for alignment.')
  if (anyDuplicated(L[[idn]])) fail('External label file has duplicated ', idn, ' values.')
  if (is.null(label_column)) { cand <- setdiff(names(L), idn); if (length(cand) != 1L) fail('Specify --label-column (candidates: ', paste(cand, collapse = ', '), ').'); label_column <- cand }
  if (!label_column %in% names(L)) fail('Label column not found: ', label_column)
  miss_ids <- setdiff(ids, L[[idn]]); extra <- setdiff(L[[idn]], ids)
  if (length(miss_ids)) fail(length(miss_ids), ' analysed ', idn, ' value(s) have no external label row (e.g. ', paste(head(miss_ids, 5), collapse = ', '), '). Alignment refused.')
  lab <- L[[label_column]][match(ids, L[[idn]])]
  list(path = lp, column = label_column, label = as.character(lab), n_missing_value = sum(is.na(lab)), n_extra_rows = length(extra))
}

# ---------------------------------------------------------------- 6A replay (only on explicit request; same approved seeds; never overwrites Stage 4)
stage6_replay <- function(stage4_dir, data, spec, output, g) {
  s4 <- resolve_path(stage4_dir); rc <- jsonlite::fromJSON(file.path(s4, 'run_config.json')); cd <- read.csv(file.path(s4, 'convergence_diagnostics.csv'))
  output_path <- resolve_path(output)
  if (path_within(output_path, s4)) fail('Replay output must not be inside the Stage 4 directory.')
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory.')
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) fail('Output directory already contains files: ', output_path)
  d <- s4_like_read(data, spec); Gs <- parse_g_em(g)
  if (!all(Gs %in% rc$g)) fail('Replay G must be among the Stage 4 fitted G values.')
  parts <- list(); chk <- list()
  for (G in Gs) {
    f <- em_fit_gmm(d$X, G, n_starts = rc$n_starts, seed = rc$seed, tol = rc$tol, max_iter = rc$max_iter, init = rc$init,
                    min_effective_n = rc$min_effective_n, max_cov_condition = rc$max_cov_condition)
    ref <- cd[cd$G == G, ]
    same_status <- identical(f$starts$status, ref$status)
    dl <- max(abs(f$starts$loglik - ref$loglik) / (1 + abs(ref$loglik)), na.rm = TRUE)
    if (!same_status || !(dl < S6_THRESHOLDS$reproduction$value)) fail(sprintf('Replay of G=%d does not reproduce Stage 4 (status match %s, max rel loglik diff %.3g). Nothing written.', G, same_status, dl))
    chk[[length(chk) + 1]] <- data.frame(G = G, n_starts = nrow(ref), statuses_identical = same_status, max_rel_loglik_diff = dl)
    for (s in seq_along(f$start_params)) if (f$starts$status[s] == 'CONVERGED_VALID') {
      e <- em_estep(d$X, f$start_params[[s]])
      parts[[length(parts) + 1]] <- data.frame(G = G, start = s, row = seq_len(nrow(d$X)), MAP = max.col(e$tau, ties.method = 'first'))
    }
  }
  P <- do.call(rbind, parts); C <- do.call(rbind, chk)
  stage_and_commit(output_path, function(dir) {
    write.csv(P, file.path(dir, 'start_partitions.csv'), row.names = FALSE)
    write.csv(C, file.path(dir, 'replay_check.csv'), row.names = FALSE)
    write_json_file(list(purpose = 'Partition-level multi-start stability (Stage 6A). Same approved seeds and settings as Stage 4; Stage 4 outputs untouched.',
                         stage4_dir = s4, settings = rc[c('n_starts', 'seed', 'tol', 'max_iter', 'init', 'min_effective_n', 'max_cov_condition')], G = I(Gs)),
                    file.path(dir, 'replay_info.json'))
  }, function(dir) if (!file.exists(file.path(dir, 'start_partitions.csv'))) fail('Replay output incomplete.'))
  invisible(list(partitions = P, check = C, output_dir = output_path))
}

s6_partition_stability <- function(P, cd, G) {
  sub <- P[P$G == G, ]; starts <- sort(unique(sub$start)); if (length(starts) < 2) return(NULL)
  lab <- lapply(starts, function(s) sub$MAP[sub$start == s][order(sub$row[sub$start == s])])
  cdg <- cd[cd$G == G, ]                                # restrict to this G BEFORE matching by start number
  best <- cdg$start[cdg$optimum %in% 1L][which.max(cdg$loglik[cdg$optimum %in% 1L])]
  grp <- cdg$optimum[match(starts, cdg$start)]
  pairs <- t(combn(seq_along(starts), 2)); ari <- apply(pairs, 1, function(ij) s6_ari(lab[[ij[1]]], lab[[ij[2]]]))
  near <- grp[pairs[, 1]] %in% 1L & grp[pairs[, 2]] %in% 1L
  to_best <- vapply(seq_along(starts), function(i) s6_ari(lab[[i]], lab[[match(best, starts)]]), numeric(1))
  # agreement between distinct local optima: representative (highest log-lik) start of each optimum group, and all cross-group start pairs
  ll <- cdg$loglik[match(starts, cdg$start)]
  groups <- sort(unique(na.omit(grp)))
  rep_of <- vapply(groups, function(g) starts[grp %in% g][which.max(ll[grp %in% g])], numeric(1))
  optima <- if (length(groups) > 1) do.call(rbind, lapply(seq_len(nrow(t(combn(groups, 2)))), function(k) {
    gg <- t(combn(groups, 2))[k, ]
    cross <- (grp[pairs[, 1]] %in% gg[1] & grp[pairs[, 2]] %in% gg[2]) | (grp[pairs[, 1]] %in% gg[2] & grp[pairs[, 2]] %in% gg[1])
    data.frame(G = G, optimum_a = gg[1], optimum_b = gg[2], n_starts_a = sum(grp %in% gg[1]), n_starts_b = sum(grp %in% gg[2]),
               loglik_a = max(ll[grp %in% gg[1]]), loglik_b = max(ll[grp %in% gg[2]]),
               ari_representatives = s6_ari(lab[[match(rep_of[groups == gg[1]], starts)]], lab[[match(rep_of[groups == gg[2]], starts)]]),
               mean_ari_cross_pairs = mean(ari[cross]), min_ari_cross_pairs = min(ari[cross]))
  })) else NULL
  within <- do.call(rbind, lapply(groups, function(g) {
    w <- grp[pairs[, 1]] %in% g & grp[pairs[, 2]] %in% g
    data.frame(G = G, optimum = g, n_starts = sum(grp %in% g), loglik = max(ll[grp %in% g]),
               mean_ari_within = if (any(w)) mean(ari[w]) else NA_real_, min_ari_within = if (any(w)) min(ari[w]) else NA_real_)
  }))
  list(mean_ari_all = mean(ari), min_ari_all = min(ari), mean_ari_near_best = if (any(near)) mean(ari[near]) else NA_real_,
       min_ari_near_best = if (any(near)) min(ari[near]) else NA_real_, ari_to_best = data.frame(G = G, start = starts, optimum = grp, ari_to_best = to_best),
       optima = optima, within = within,
       pairwise = data.frame(G = G, start_a = starts[pairs[, 1]], start_b = starts[pairs[, 2]], optimum_a = grp[pairs[, 1]], optimum_b = grp[pairs[, 2]], ari = ari))
}

# ---------------------------------------------------------------- main
stage6_validate <- function(stage4_dir, stage5_dir, data, spec, labels, output, label_column = NULL, compare_g = NULL,
                            replay_dir = NULL, strata = NULL, strata_columns = NULL, config_file = NULL) {
  s4 <- resolve_path(stage4_dir); s5 <- resolve_path(stage5_dir); output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  for (f in c('model_comparison.csv', 'convergence_diagnostics.csv', 'all_models_parameters.json', 'selected_model.json')) if (!file.exists(file.path(s4, f))) fail('Stage 4 directory lacks ', f)
  for (f in c('classification.csv', 'component_summary.csv', 'component_means.csv', 'component_sd_original.csv', 'stage5_summary.json')) if (!file.exists(file.path(s5, f))) fail('Stage 5 directory lacks ', f)
  d <- s4_like_read(data, spec); X <- d$X; feats <- d$feats; idn <- if (is.null(d$idc)) 'row_id' else d$idc
  mc <- read.csv(file.path(s4, 'model_comparison.csv')); cd <- read.csv(file.path(s4, 'convergence_diagnostics.csv'))
  sj <- jsonlite::fromJSON(file.path(s4, 'selected_model.json'), simplifyVector = TRUE)
  allp <- jsonlite::fromJSON(file.path(s4, 'all_models_parameters.json'), simplifyVector = FALSE)
  s5s <- jsonlite::fromJSON(file.path(s5, 'stage5_summary.json'), simplifyVector = TRUE)
  if (!identical(sj$spec$spec_hash, d$sp$spec_hash) || !identical(s5s$spec$spec_hash, d$sp$spec_hash)) fail('Stage 4/5 outputs belong to a different Stage 3 spec (spec_hash mismatch).')
  Gsel <- as.integer(sj$selected_G)
  cls <- read.csv(file.path(s5, 'classification.csv'), check.names = FALSE)
  if (!identical(cls[[idn]], d$ids)) fail('Stage 5 classification.csv row IDs do not match the analysis data.')
  sel_map <- cls$MAP_component
  if (is.null(compare_g)) {
    aic <- mc$G[mc$selected_AIC %in% TRUE]; alts <- unlist(sj$alternatives_for_stage6)
    compare_g <- unique(c(alts, if (length(aic) && aic != Gsel) aic))
  } else compare_g <- parse_g_em(compare_g)
  compare_g <- setdiff(as.integer(compare_g), Gsel)

  # ---- evaluate saved parameters (no refit) -----------------------------------------------------
  eval_saved <- function(G) {
    m <- allp[[paste0('G', G)]]; if (is.null(m) || !isTRUE(m$eligible)) fail('Stage 4 has no valid saved model for G = ', G, '.')
    par <- s6_par_from_json(m, feats); e <- em_estep(X, par)
    if (!e$ok) fail('Saved parameters for G = ', G, ' cannot be evaluated: ', e$reason)
    rel <- abs(e$loglik - m$loglik) / (1 + abs(m$loglik))
    if (rel > S6_THRESHOLDS$reproduction$value) fail(sprintf('Saved G = %d parameters do not reproduce the saved log-likelihood (rel diff %.3g).', G, rel))
    list(G = G, par = par, tau = e$tau, unc = s5_uncertainty(e$tau), loglik = e$loglik, rel_diff = rel)
  }
  msel <- eval_saved(Gsel)
  if (!identical(msel$unc$MAP_component, sel_map)) fail('Stage 5 MAP classification differs from the saved Stage 4 selected parameters.')
  malt <- lapply(compare_g, eval_saved); if (length(compare_g)) names(malt) <- paste0('G', compare_g) # no alternative G is a normal outcome

  # ---- 6A stability ----------------------------------------------------------------------------
  stab <- do.call(rbind, lapply(sort(unique(cd$G)), function(G) {
    x <- cd[cd$G == G, ]; v <- x$status == 'CONVERGED_VALID'; ng <- x$optimum[v]
    gap2 <- if (length(unique(ng)) > 1) { b <- max(x$loglik[v]); sort(unique(round(b - x$loglik[v & x$optimum != 1], 6)))[1] } else NA_real_
    data.frame(G = G, n_starts = nrow(x), n_valid = sum(v), n_distinct_optima = length(unique(ng)), n_near_best = sum(ng == 1L),
               share_near_best = if (sum(v)) mean(ng == 1L) else NA_real_,
               max_aligned_d_mu_near_best = if (any(ng == 1L)) max(x$aligned_max_d_mu[v][ng == 1L]) else NA_real_,
               max_aligned_d_sigma_near_best = if (any(ng == 1L)) max(x$aligned_max_d_sigma[v][ng == 1L]) else NA_real_,
               loglik_gap_next_optimum = gap2, label_switching_across_starts = length(unique(na.omit(x$label_permutation))) > 1,
               partition_mean_ari_near_best = NA_real_, partition_min_ari_near_best = NA_real_, partition_mean_ari_all_valid = NA_real_,
               partition_min_ari_all_valid = NA_real_, partition_level = 'not computed: per-start partitions not saved by Stage 4 (requires approved replay)')
  }))
  ari_to_best <- NULL; ari_optima <- NULL; ari_within <- NULL; ari_pairs <- NULL; replay_info <- NULL
  if (!is.null(replay_dir)) {
    rdir <- resolve_path(replay_dir)
    for (f in c('start_partitions.csv', 'replay_check.csv', 'replay_info.json')) if (!file.exists(file.path(rdir, f))) fail('Replay directory lacks ', f)
    rchk <- read.csv(file.path(rdir, 'replay_check.csv'))
    if (!all(rchk$statuses_identical) || any(rchk$max_rel_loglik_diff >= S6_THRESHOLDS$reproduction$value)) fail('Replay did not reproduce Stage 4; partition stability not computed.')
    replay_info <- list(dir = rdir, check = rchk)
    P <- read.csv(file.path(rdir, 'start_partitions.csv'))
    if (max(P$row) != nrow(X)) fail('Replay partitions do not match the analysis data size.')
    stab$partition_n_distinct_partitions <- NA_integer_
    for (G in intersect(unique(P$G), stab$G)) {
      ps <- s6_partition_stability(P, cd, G); if (is.null(ps)) next
      k <- stab$G == G
      stab$partition_mean_ari_near_best[k] <- ps$mean_ari_near_best; stab$partition_min_ari_near_best[k] <- ps$min_ari_near_best
      stab$partition_mean_ari_all_valid[k] <- ps$mean_ari_all; stab$partition_min_ari_all_valid[k] <- ps$min_ari_all
      stab$partition_level[k] <- 'computed from approved replay (same per-start seeds as Stage 4, reproduction verified)'
      ari_to_best <- rbind(ari_to_best, ps$ari_to_best); ari_optima <- rbind(ari_optima, ps$optima)
      ari_within <- rbind(ari_within, ps$within); ari_pairs <- rbind(ari_pairs, ps$pairwise)
    }
  }

  # ---- 6B sensitivity --------------------------------------------------------------------------
  sens_row <- function(m, role) {
    r <- mc[mc$G == m$G, ]
    data.frame(G = m$G, role = role, loglik = m$loglik, k_G = r$k_G, BIC = r$BIC, delta_BIC = r$delta_BIC, AIC = r$AIC, delta_AIC = r$delta_AIC,
               mixing_proportions = paste(sprintf('%.3f', m$par$pi), collapse = '; '), MAP_sizes = paste(tabulate(m$unc$MAP_component, m$G), collapse = '; '),
               min_MAP_size = min(tabulate(m$unc$MAP_component, m$G)), mean_uncertainty = mean(m$unc$uncertainty),
               n_U_gt_0.10 = sum(m$unc$uncertainty > .10), mean_entropy = mean(m$unc$entropy_normalized),
               max_cov_condition = max(em_cov_conditions(m$par)), min_effective_n = min(colSums(m$tau)),
               n_distinct_optima = stab$n_distinct_optima[stab$G == m$G], share_near_best = stab$share_near_best[stab$G == m$G],
               diagnostic_warnings = r$diagnostic_warnings, ARI_vs_selected = s6_ari(m$unc$MAP_component, sel_map),
               NMI_vs_selected = s6_nmi(m$unc$MAP_component, sel_map), stringsAsFactors = FALSE)
  }
  sens <- do.call(rbind, c(list(sens_row(msel, 'selected (BIC)')), lapply(malt, sens_row, role = 'alternative (sensitivity)')))
  splits <- lapply(malt, function(m) s6_split_analysis(sel_map, m$unc$MAP_component))

  # ---- 6C external validation ------------------------------------------------------------------
  # External labels are optional: without them 6C is skipped (reported as not performed); nothing else changes.
  has_labels <- !is.null(labels)
  lb <- NULL; ext_sel <- NULL; ext_alt <- list(); comp_lab <- NULL
  if (has_labels) {
  lb <- s6_read_labels(labels, label_column, d$ids, idn)
  ok <- !is.na(lb$label)
  ext_for <- function(mapv, G) {
    tab <- table(component = factor(mapv[ok], levels = seq_len(G)), label = lb$label[ok])
    ma <- s6_matched_agreement(tab)
    list(G = G, n_used = sum(ok), n_label_missing = sum(!ok), ARI = s6_ari(mapv[ok], lb$label[ok]), NMI = s6_nmi(mapv[ok], lb$label[ok]),
         table = tab, matched = ma)
  }
  ext_sel <- ext_for(sel_map, Gsel); ext_alt <- lapply(malt, function(m) ext_for(m$unc$MAP_component, m$G))
  long_tab <- function(e, role) {
    T <- e$table; rp <- sweep(T, 1, pmax(rowSums(T), 1), '/'); cp <- sweep(T, 2, pmax(colSums(T), 1), '/')
    g <- expand.grid(component = rownames(T), label = colnames(T), stringsAsFactors = FALSE)
    data.frame(model_G = e$G, role = role, g, count = as.vector(T), row_proportion = as.vector(rp), column_proportion = as.vector(cp))
  }
  comp_lab <- do.call(rbind, c(list(long_tab(ext_sel, 'selected (BIC)')), lapply(ext_alt, long_tab, role = 'alternative (sensitivity)')))
  }

  # ---- 6D profiling ----------------------------------------------------------------------------
  csum <- read.csv(file.path(s5, 'component_summary.csv')); cmean <- read.csv(file.path(s5, 'component_means.csv'), check.names = FALSE)
  csd <- read.csv(file.path(s5, 'component_sd_original.csv'), check.names = FALSE); cmean <- cmean[cmean$scale == 'original', ]
  prof <- data.frame(component = csum$component, mixing_proportion = csum$mixing_proportion, effective_n = csum$effective_n, MAP_count = csum$MAP_count,
                     mean_uncertainty = csum$mean_uncertainty_MAP,
                     setNames(cmean[match(csum$component, cmean$component), feats, drop = FALSE], paste0('mean_', feats)),
                     setNames(csd[match(csum$component, csd$component), feats, drop = FALSE], paste0('sd_', feats)), check.names = FALSE)
  if (has_labels) {
    T <- ext_sel$table; rp <- sweep(T, 1, pmax(rowSums(T), 1), '/')
    prof$posthoc_majority_label <- colnames(T)[apply(T, 1, which.max)]; prof$posthoc_majority_share <- apply(rp, 1, max)
    prof$posthoc_label_composition <- apply(T, 1, function(r) paste(sprintf('%s=%d', colnames(T), r)[r > 0], collapse = '; '))
  }
  prof$substantive_interpretation <- 'not established by this analysis'

  # ---- optional strata check (descriptive only) ------------------------------------------------
  strata_out <- NULL; strata_info <- NULL
  if (!is.null(strata)) {
    sp_ <- resolve_path(strata); if (!file.exists(sp_)) fail('Strata file not found: ', sp_)
    S <- read.csv(sp_, check.names = FALSE, stringsAsFactors = FALSE)
    key <- if (idn %in% names(S)) S[[idn]] else seq_len(nrow(S)) # Stage 2 source_row_id = row number of the original input
    cols <- if (is.null(strata_columns)) character() else trimws(strsplit(strata_columns, ',')[[1]])
    missing_cols <- setdiff(cols, names(S))
    strata_info <- list(file = sp_, id_basis = if (idn %in% names(S)) idn else 'row number (= Stage 2 source_row_id)', requested = I(cols), missing = I(missing_cols))
    for (cc in setdiff(cols, missing_cols)) {
      v <- as.character(S[[cc]][match(d$ids, key)])
      tt <- table(stratum = v, component = factor(sel_map, levels = seq_len(Gsel)), useNA = 'ifany')
      strata_out <- rbind(strata_out, data.frame(variable = cc, stratum = rownames(tt), n = as.integer(rowSums(tt)),
                                                 as.data.frame.matrix(tt, optional = TRUE) |> setNames(paste0('component_', seq_len(Gsel))), check.names = FALSE))
    }
  }

  # ---- summary objects ---------------------------------------------------------------------------
  ext_json <- function(e) list(G = e$G, n_used = e$n_used, n_label_missing = e$n_label_missing, ARI = e$ARI, NMI = e$NMI,
                               table = lapply(seq_len(nrow(e$table)), function(i) as.list(setNames(as.integer(e$table[i, ]), colnames(e$table)))),
                               matched_agreement = list(value = e$matched$agreement, method = S6_THRESHOLDS$matched_agreement$value,
                                                        mapping = e$matched$mapping, note = e$matched$note))
  external <- if (has_labels) list(available = TRUE, label_file = lb$path, label_column = lb$column, alignment_key = idn, n_extra_label_rows = lb$n_extra_rows,
                   use = 'post-hoc evaluation only; the label was not used to estimate parameters or to select G',
                   selected = ext_json(ext_sel), alternatives = lapply(ext_alt, ext_json),
                   interpretation_guide = 'ARI: 1 identical, ~0 chance-level, can be negative. NMI: 0 independent, 1 identical. Both are label-invariant (no component-label alignment needed).')
              else list(available = FALSE, note = 'No external labels were provided; 6C external validation was not performed.')
  summary <- list(stage = 6, script_version = S6_VERSION, generated_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
    spec = list(spec_hash = d$sp$spec_hash, approval_id = d$sp$approval_id), selected_G = Gsel, compared_G = I(compare_g),
    saved_parameter_reproduction = c(list(selected = msel$rel_diff), lapply(malt, `[[`, 'rel_diff')),
    stability = list(multistart = stab, replay_used = !is.null(replay_dir), replay = replay_info,
                     within_optimum_ari = ari_within, between_optima_ari = ari_optima,
                     bootstrap_subsampling = 'NOT RUN (optional; requires user approval of resampling settings)'),
    sensitivity = c(list(table = sens, structure = lapply(splits, `[[`, 'events')), if (!length(compare_g)) list(note = S6_NO_ALTERNATIVE)),
    external_validation = if (has_labels) list(available = TRUE, ARI = ext_sel$ARI, NMI = ext_sel$NMI, matched_agreement = ext_sel$matched$agreement)
                          else list(available = FALSE, note = 'no external labels provided'),
    strata_check = strata_info, thresholds = S6_THRESHOLDS,
    carried_warnings = list(independence = list(status = d$sp$rows_independent, note = d$sp$independence_note), outlier_policy = d$sp$outlier_policy),
    primary_model = sprintf('G = %d (BIC). Not changed by Stage 6.', Gsel), output_dir = output_path)
  run_config <- list(script_version = S6_VERSION, stage4_dir = s4, stage5_dir = s5, data = d$input_path, spec = d$spec_path, labels = lb$path,
                     label_column = lb$column, compare_g = I(compare_g), replay_dir = if (!is.null(replay_dir)) resolve_path(replay_dir) else NULL,
                     strata = if (!is.null(strata)) resolve_path(strata) else NULL, strata_columns = strata_columns,
                     config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL, r_version = R.version.string)

  required <- c('stability_summary.csv', 'model_sensitivity.csv', 'external_validation.json', 'cluster_profiles.csv',
                'stage6_summary.json', 'stability_plot.png', 'model_sensitivity_plot.png', 'stage6_report.md', 'run_config.json',
                if (length(compare_g)) paste0('crosstab_selected_vs_G', compare_g, '.csv'), if (has_labels) c('component_label_table.csv', 'component_label_heatmap.png'))
  writer <- function(dir) {
    write.csv(stab, file.path(dir, 'stability_summary.csv'), row.names = FALSE)
    if (!is.null(ari_to_best)) {
      write.csv(ari_to_best, file.path(dir, 'stability_partitions_ari.csv'), row.names = FALSE)
      write.csv(ari_pairs, file.path(dir, 'stability_pairwise_ari.csv'), row.names = FALSE)
      write.csv(ari_within, file.path(dir, 'stability_within_optimum_ari.csv'), row.names = FALSE)
      write.csv(if (is.null(ari_optima)) data.frame(G = integer(), optimum_a = integer(), optimum_b = integer(), ari_representatives = numeric()) else ari_optima,
                file.path(dir, 'stability_between_optima_ari.csv'), row.names = FALSE)
    }
    write.csv(sens, file.path(dir, 'model_sensitivity.csv'), row.names = FALSE)
    for (nm in names(splits)) {
      T <- splits[[nm]]$table
      write.csv(cbind(selected_component = rownames(T), as.data.frame.matrix(T)) |> setNames(c('selected_component', paste0(nm, '_component_', colnames(T)))),
                file.path(dir, paste0('crosstab_selected_vs_', nm, '.csv')), row.names = FALSE)
    }
    if (has_labels) write.csv(comp_lab, file.path(dir, 'component_label_table.csv'), row.names = FALSE)
    write_json_file(external, file.path(dir, 'external_validation.json'))
    write.csv(prof, file.path(dir, 'cluster_profiles.csv'), row.names = FALSE)
    if (!is.null(strata_out)) write.csv(strata_out, file.path(dir, 'strata_check.csv'), row.names = FALSE)
    s6_plot_stability(cd, stab, Gsel, compare_g, file.path(dir, 'stability_plot.png'))
    if (has_labels) s6_plot_labels(ext_sel, ext_alt, file.path(dir, 'component_label_heatmap.png'))
    s6_plot_sensitivity(sens, splits, Gsel, file.path(dir, 'model_sensitivity_plot.png'))
    write_json_file(summary, file.path(dir, 'stage6_summary.json'))
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    writeLines(s6_report_md(summary, stab, sens, splits, ext_sel, ext_alt, prof, strata_out, lb, feats, idn), file.path(dir, 'stage6_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) { bad <- required[!file.exists(file.path(dir, required))]; if (length(bad)) fail('Staged Stage 6 output incomplete: ', paste(bad, collapse = ', ')) }
  stage_and_commit(output_path, writer, validator)
  invisible(list(stability = stab, sensitivity = sens, splits = splits, external = ext_sel, external_alt = ext_alt, profiles = prof,
                 strata = strata_out, summary = summary, output_dir = output_path))
}

# ---------------------------------------------------------------- plots
s6_heat <- function(M, main, txt = NULL, zlim = c(0, 1), pal = colorRampPalette(c('#F7F7F7', '#2F5D85'))(101)) {
  r <- nrow(M); k <- ncol(M)
  image(seq_len(k), seq_len(r), t(M[r:1, , drop = FALSE]), zlim = zlim, col = pal, axes = FALSE, xlab = '', ylab = '', main = main, cex.main = .9)
  axis(1, seq_len(k), colnames(M), las = 2, cex.axis = .8); axis(2, seq_len(r), rev(rownames(M)), las = 1, cex.axis = .8)
  if (is.null(txt)) txt <- matrix(sprintf('%.2f', M), r, k)
  for (i in seq_len(r)) for (j in seq_len(k)) text(j, r + 1 - i, txt[i, j], cex = .8, col = if (M[i, j] > .6 * zlim[2]) 'white' else 'black')
  box()
}
s6_plot_stability <- function(cd, stab, Gsel, cmp, file) {
  Gs <- sort(unique(cd$G)); nc <- min(3, length(Gs)); nr <- ceiling(length(Gs) / nc)
  png(file, width = 480 * nc, height = 400 * nr + 60, res = 115); on.exit(dev.off())
  par(mfrow = c(nr, nc), mar = c(4.2, 4.6, 3.6, 1), oma = c(0, 0, 2.2, 0))
  for (G in Gs) {
    x <- cd[cd$G == G, ]; v <- x$status == 'CONVERGED_VALID'; b <- max(x$loglik[v], na.rm = TRUE)
    gap <- ifelse(v, b - x$loglik, NA); grp <- ifelse(v, x$optimum, NA)
    plot(x$start, gap, pch = ifelse(v, 19, 4), col = ifelse(is.na(grp), 'grey60', c('#2F5D85', '#C65C48', '#3F8F5A', '#8E6BB5', '#C9962B', '#4BA3B5', '#B5577F', '#6E6E6E')[pmin(grp, 8)]),
         ylim = c(0, max(1, gap, na.rm = TRUE) * 1.08), xlab = 'Start', ylab = 'best log-lik - start log-lik',
         main = sprintf('G = %d%s', G, if (G == Gsel) ' (selected)' else if (G %in% cmp) ' (alternative)' else ''))
    s <- stab[stab$G == G, ]
    mtext(sprintf('%d/%d valid; %d optima; %d near best', s$n_valid, s$n_starts, s$n_distinct_optima, s$n_near_best), side = 3, line = .2, cex = .72)
  }
  mtext('6A multi-start stability: gap of each start to the best optimum (colour = optimum group after label alignment; 0 = best)', outer = TRUE, font = 2, cex = .85)
}
s6_plot_labels <- function(es, ea, file) {
  all <- c(list(es), ea); k <- length(all)
  png(file, width = 620 * k, height = 560, res = 115); on.exit(dev.off())
  par(mfrow = c(1, k), mar = c(7, 7, 4.5, 1))
  for (i in seq_len(k)) {
    e <- all[[i]]; T <- e$table; rp <- sweep(T, 1, pmax(rowSums(T), 1), '/')
    M <- matrix(rp, nrow(T), dimnames = list(paste('Comp.', rownames(T)), colnames(T)))
    s6_heat(M, sprintf('%s G = %d: row proportions (counts)\nARI = %.3f, NMI = %.3f (post-hoc labels)', if (i == 1) 'Selected' else 'Alternative', e$G, e$ARI, e$NMI),
            txt = matrix(sprintf('%.2f\n(%d)', rp, T), nrow(T)))
  }
}
s6_plot_sensitivity <- function(sens, splits, Gsel, file) {
  k <- length(splits)
  png(file, width = 520 * (2 + k), height = 520, res = 115); on.exit(dev.off())
  par(mfrow = c(1, 2 + k), mar = c(5, 5, 4.5, 1))
  dm <- rbind(BIC = sens$delta_BIC, AIC = sens$delta_AIC); colnames(dm) <- paste0('G=', sens$G)
  b <- barplot(dm, beside = TRUE, col = c('#2F5D85', '#C65C48'), border = NA, ylab = 'delta from best over all G', main = 'Information criteria\n(0 = best among G candidates)', cex.main = .9)
  text(b, dm, sprintf('%.1f', dm), pos = 3, cex = .8, xpd = TRUE); legend('topleft', c('delta BIC', 'delta AIC'), fill = c('#2F5D85', '#C65C48'), bty = 'n', border = NA)
  sz <- lapply(strsplit(sens$MAP_sizes, '; '), as.integer); mx <- max(lengths(sz))
  Ms <- vapply(sz, function(v) c(v, rep(0, mx - length(v))), numeric(mx)); colnames(Ms) <- paste0('G=', sens$G)
  barplot(Ms, col = hcl.colors(mx, 'Dark 3'), border = 'white', ylab = 'MAP count', main = 'MAP component sizes\n(stacked by component)', cex.main = .9)
  for (nm in names(splits)) {
    T <- splits[[nm]]$table; rp <- sweep(T, 1, rowSums(T), '/')
    M <- matrix(rp, nrow(T), dimnames = list(paste0('sel ', rownames(T)), paste0('alt ', colnames(T))))
    s6_heat(M, sprintf('Selected G=%d (rows) vs %s (cols)\nrow proportions (counts)', Gsel, nm), txt = matrix(sprintf('%.2f\n(%d)', rp, T), nrow(T)))
  }
}

# ---------------------------------------------------------------- report
S6_NO_ALTERNATIVE <- 'No alternative G was compared.'
# Reads only the Stage 3 status field; the free-text note is shown verbatim and never interpreted.
s6_independence_text <- function(status) {
  if (isTRUE(status)) 'confirmed by the user at Stage 3'
  else if (identical(status, 'working assumption')) 'recorded as a working assumption at Stage 3'
  else if (is.null(status) || !length(status)) 'not recorded in the Stage 3 specification'
  else sprintf('recorded at Stage 3 as %s', paste(format(status), collapse = ', '))
}
s6_report_md <- function(s, stab, sens, splits, es, ea, prof, strata, lb, feats, idn) {
  f3 <- function(x) ifelse(is.na(x), '-', sprintf('%.3f', x))
  has_labels <- !is.null(es)
  L <- c('# Stage 6 - Validation and profiling', '',
         sprintf('- Primary model: **%s** Spec `%s` (approval `%s`).', s$primary_model, s$spec$spec_hash, s$spec$approval_id),
         sprintf('- Saved Stage 4 parameters re-evaluated (no refit); relative log-likelihood differences: %s.',
                 paste(sprintf('%s %.1e', names(s$saved_parameter_reproduction), unlist(s$saved_parameter_reproduction)), collapse = ', ')),
         if (has_labels) '- The external label was read only in 6C and used only for post-hoc evaluation. GMM is unsupervised; the label is not a training label and did not influence estimation or model selection.' else '- No external labels were provided to Stage 6.',
         '', '## 6A Multi-start stability (from saved Stage 4 diagnostics)', '',
         '| G | valid | distinct optima | starts at best optimum | share | max aligned d(mu) at best | max aligned d(Sigma) at best | log-lik gap to next optimum | partition ARI (best-group mean / all-valid mean) |',
         '|---|---|---|---|---|---|---|---|---|',
         sprintf('| %d | %d/%d | %d | %d | %s | %s | %s | %s | %s |', stab$G, stab$n_valid, stab$n_starts, stab$n_distinct_optima, stab$n_near_best,
                 f3(stab$share_near_best), formatC(stab$max_aligned_d_mu_near_best, format = 'g', digits = 2), formatC(stab$max_aligned_d_sigma_near_best, format = 'g', digits = 2),
                 ifelse(is.na(stab$loglik_gap_next_optimum), '-', sprintf('%.2f', stab$loglik_gap_next_optimum)),
                 ifelse(is.na(stab$partition_mean_ari_all_valid), 'not computed', sprintf('%.3f / %.3f', stab$partition_mean_ari_near_best, stab$partition_mean_ari_all_valid))),
         '', paste('Parameter comparisons use label-aligned differences (Stage 4C). "At best optimum" = starts in the best optimum group; "all valid" includes other local optima.',
                   if (all(is.na(stab$partition_mean_ari_all_valid))) 'Partition-level ARI between starts needs per-start classifications, which Stage 4 did not save; it requires a replay of the same approved seeds (`--mode replay`) with user approval.' else ''),
         if (isTRUE(s$stability$replay_used)) c('', sprintf('**Partition-level ARI between starts** (replay of the same per-start seeds; reproduction verified: max relative log-lik difference %s). ARI is label-invariant, so no component alignment is needed.',
                                                         paste(sprintf('G=%d %.1e', s$stability$replay$check$G, s$stability$replay$check$max_rel_loglik_diff), collapse = ', ')), '',
                                                 '| G | optimum | starts | log-lik | mean ARI within | min ARI within |', '|---|---|---|---|---|---|',
                                                 with(s$stability$within_optimum_ari, sprintf('| %d | %d | %d | %.4f | %s | %s |', G, optimum, n_starts, loglik, f3(mean_ari_within), f3(min_ari_within))),
                                                 if (!is.null(s$stability$between_optima_ari) && NROW(s$stability$between_optima_ari)) c('', '| G | optimum a | optimum b | log-lik a | log-lik b | ARI (best start of each) | mean / min ARI over cross pairs |', '|---|---|---|---|---|---|---|',
                                                   with(s$stability$between_optima_ari, sprintf('| %d | %d | %d | %.4f | %.4f | %.4f | %.4f / %.4f |', G, optimum_a, optimum_b, loglik_a, loglik_b, ari_representatives, mean_ari_cross_pairs, min_ari_cross_pairs)))) else character(),
         sprintf('- Bootstrap / subsampling stability: %s', s$stability$bootstrap_subsampling),
         '', '## 6B Model sensitivity (selected vs alternative)', '',
         '| G | role | log-lik | k_G | BIC (delta) | AIC (delta) | pi | MAP sizes | mean U | U > 0.10 | max cov cond. | distinct optima | ARI / NMI vs selected |',
         '|---|---|---|---|---|---|---|---|---|---|---|---|---|',
         sprintf('| %d | %s | %.3f | %d | %.2f (%.2f) | %.2f (%.2f) | %s | %s | %.4f | %d | %.3g | %d | %.3f / %.3f |', sens$G, sens$role, sens$loglik, as.integer(sens$k_G), sens$BIC,
                 sens$delta_BIC, sens$AIC, sens$delta_AIC, sens$mixing_proportions, sens$MAP_sizes, sens$mean_uncertainty, sens$n_U_gt_0.10, sens$max_cov_condition,
                 sens$n_distinct_optima, sens$ARI_vs_selected, sens$NMI_vs_selected), '')
  for (nm in names(splits)) {
    T <- splits[[nm]]$table
    L <- c(L, sprintf('**Selected G = %d (rows) vs %s (columns), MAP counts**', s$selected_G, nm), '',
           paste0('| selected \\ alternative | ', paste(colnames(T), collapse = ' | '), ' |'), paste0('|---|', strrep('---|', ncol(T))),
           sprintf('| %s | %s |', rownames(T), apply(T, 1, paste, collapse = ' | ')), '', paste('-', splits[[nm]]$events), '')
  }
  L <- c(L, if (length(splits)) 'Components of models with different G are not paired one-to-one; the structure is read from the cross-table. The primary model remains the BIC choice.' else paste(S6_NO_ALTERNATIVE, 'The primary model remains the BIC choice.'), '',
         '## 6C External validation (post-hoc)', '',
         if (is.null(es)) '- **External Validation: Not Performed.** No external labels were provided; external validation was not performed.' else
         sprintf('- Label file `%s`, column `%s`, aligned by `%s`; %d rows used, %d with missing label value; %d label rows not in the analysis.',
                 basename(lb$path), lb$column, idn, es$n_used, es$n_label_missing, lb$n_extra_rows))
  for (e in if (is.null(es)) list() else c(list(es), ea)) {
    T <- e$table; rp <- sweep(T, 1, pmax(rowSums(T), 1), '/'); cp <- sweep(T, 2, pmax(colSums(T), 1), '/')
    L <- c(L, '', sprintf('### %s model G = %d: ARI = %.4f, NMI = %.4f', if (identical(e, es)) 'Selected' else 'Alternative', e$G, e$ARI, e$NMI), '',
           paste0('| component \\ label | ', paste(colnames(T), collapse = ' | '), ' | total |'), paste0('|---|', strrep('---|', ncol(T) + 1)),
           sprintf('| %s | %s | %d |', rownames(T), apply(matrix(sprintf('%d (row %.2f, col %.2f)', T, rp, cp), nrow(T)), 1, paste, collapse = ' | '), as.integer(rowSums(T))),
           '', if (!is.na(e$matched$agreement)) sprintf('- Matched agreement after optimal one-to-one matching of components to labels: %.4f (%s). This is a descriptive post-hoc figure, distinct from ARI/NMI, and depends on the matching.',
                                                         e$matched$agreement, paste(sprintf('comp %s -> %s', e$matched$mapping$component, ifelse(is.na(e$matched$mapping$matched_label), 'unmatched', e$matched$mapping$matched_label)), collapse = ', ')) else '')
  }
  hl <- 'posthoc_majority_label' %in% names(prof)
  L <- c(L, '', '## 6D Cluster profiles', '', if (hl) '*Model features* (Stage 5, original units) are separated from *post-hoc label associations* and from *unestablished substantive interpretation*.' else '*Model features* (Stage 5, original units) are separated from *unestablished substantive interpretation*.', '',
         paste0('| component | pi | MAP n | mean U | ', paste(paste0('mean ', feats), collapse = ' | '), if (hl) ' | post-hoc majority label (share) | composition |' else ' |'),
         paste0('|---|---|---|---|', strrep('---|', length(feats)), if (hl) '---|---|' else ''))
  for (i in seq_len(nrow(prof))) L <- c(L, paste0(sprintf('| %d | %.3f | %d | %.4f | %s |', prof$component[i], prof$mixing_proportion[i], prof$MAP_count[i], prof$mean_uncertainty[i],
                                                          paste(formatC(unlist(prof[i, paste0('mean_', feats)]), format = 'fg', digits = 4), collapse = ' | ')),
                                                  if (hl) sprintf(' %s (%.2f) | %s |', prof$posthoc_majority_label[i], prof$posthoc_majority_share[i], prof$posthoc_label_composition[i])))
  L <- c(L, '', if (hl) '- Substantive interpretation: not established by this analysis (the association with external labels is observational and post hoc).' else '- Substantive interpretation: not established by this analysis.')
  if (!is.null(strata)) {
    L <- c(L, '', '## Sampling-structure check (descriptive only; separate from the main analysis)', '',
           'Counts of the selected-model MAP components within each stratum. No model was refitted by stratum; a stratified refit would need its own approval and enough rows per stratum.', '',
           paste0('| variable | stratum | n | ', paste(grep('^component_', names(strata), value = TRUE), collapse = ' | '), ' |'), paste0('|---|---|---|', strrep('---|', sum(grepl('^component_', names(strata))))),
           sprintf('| %s | %s | %d | %s |', strata$variable, strata$stratum, strata$n, apply(strata[, grep('^component_', names(strata)), drop = FALSE], 1, paste, collapse = ' | ')))
  }
  L <- c(L, '', '## Limitations and carried warnings', '',
         sprintf('- Independence: %s.%s', s6_independence_text(s$carried_warnings$independence$status), if (is.null(s$carried_warnings$independence$note)) '' else paste0(' ', s$carried_warnings$independence$note)),
         sprintf('- Outliers: %s.', s$carried_warnings$outlier_policy),
         '- Gaussian components are density components and are not necessarily natural groups.',
         if (has_labels) '- Agreement with external labels does not prove that components are natural groups, and disagreement does not prove the labels wrong.',
         '- Posterior probabilities are model-based; they are not verified classification accuracy.')
  enc2utf8(L)
}

# ---------------------------------------------------------------- CLI
s6_cli <- function(argv) {
  keys <- c('mode', 'stage4-dir', 'stage5-dir', 'data', 'spec', 'labels', 'label-column', 'compare-g', 'replay-dir', 'strata', 'strata-columns', 'g', 'output', 'config')
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
  mode <- if (is.null(a$mode)) 'validate' else a$mode
  if (mode == 'replay') {
    miss <- setdiff(c('stage4-dir', 'data', 'spec', 'output', 'g'), names(a)); if (length(miss)) fail('Missing settings for replay: ', paste(miss, collapse = ', '))
    return(stage6_replay(a[['stage4-dir']], a$data, a$spec, a$output, a$g))
  }
  if (mode != 'validate') fail('--mode must be validate or replay.')
  miss <- setdiff(c('stage4-dir', 'stage5-dir', 'data', 'spec', 'output'), names(a)); if (length(miss)) fail('Missing settings: ', paste(miss, collapse = ', '))
  stage6_validate(a[['stage4-dir']], a[['stage5-dir']], a$data, a$spec, a$labels, a$output, label_column = a[['label-column']], compare_g = a[['compare-g']],
                  replay_dir = a[['replay-dir']], strata = a$strata, strata_columns = a[['strata-columns']], config_file = a$config)
}

if (sys.nframe() == 0L) {
  r <- tryCatch(s6_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
  if (!is.null(r$summary) && is.null(r$external)) {
    cat('No external labels: 6C not performed.\n'); for (sp in r$splits) cat(paste(sp$events, collapse = '\n'), '\n')
  } else if (!is.null(r$external)) {
    cat(sprintf('Selected G=%d: ARI = %.4f, NMI = %.4f\n', r$summary$selected_G, r$external$ARI, r$external$NMI))
    for (e in r$external_alt) cat(sprintf('Alternative G=%d: ARI = %.4f, NMI = %.4f\n', e$G, e$ARI, e$NMI))
    for (sp in r$splits) cat(paste(sp$events, collapse = '\n'), '\n')
  } else print(r$check)
  cat('Output directory:', r$output_dir, '\n')
}
