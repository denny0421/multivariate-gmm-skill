#!/usr/bin/env Rscript
# Stage 5 - Interpretation of the selected Gaussian mixture (generic; any p, any G >= 1).
# Reads the Stage 4 selection outputs (selected_model.rds, posterior_selected.csv, selected_model.json, model_comparison.csv),
# the approved Stage 3 spec and transform parameters. Never refits, never re-selects, never uses an external label.
# Back-transformation of an affine per-variable scaling x = m + S z (S = diag(sd)):
#   mu_original = m + S mu_z ;  Sigma_original = S Sigma_z S ;  correlations are unchanged.
# Posterior probabilities are invariant: log phi(x; mu_o, Sigma_o) = log phi(z; mu_z, Sigma_z) - log|S| for every component.
suppressPackageStartupMessages(library(jsonlite))

s5_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
S5_SCRIPT_DIR <- dirname(s5_script_path())
source(file.path(S5_SCRIPT_DIR, 'em_stage4.R'), local = TRUE) # em_estep / em_logdens (unchanged), path + staging utilities

S5_VERSION <- '0.1.0'
S5_THRESHOLDS <- list(
  uncertainty = list(formula = 'U_j = 1 - max_i tau_ji', type = 'exact'),
  entropy = list(formula = 'H_j = -sum_i tau_ji log tau_ji / log G  (0 log 0 = 0; H_j = 0 when G = 1)', type = 'exact'),
  ambiguous = list(value = 0.10, type = 'heuristic', use = 'observations with U_j > 0.10 are listed as ambiguous (not removed, not reclassified)'),
  descriptor = list(value = 0.5, type = 'heuristic', use = 'a component mean is described as higher/lower than the overall mean when |difference| >= 0.5 overall SD'),
  posterior_reproduction = list(value = 1e-8, type = 'numerical tolerance', use = 'max |tau recomputed - tau stored|'),
  invariance = list(value = 1e-8, type = 'numerical tolerance', use = 'max |tau(original scale) - tau(fitted scale)|'))

# ---------------------------------------------------------------- core (pure functions; unit-tested)
s5_back_transform <- function(par, center, scale) {
  if (is.null(center)) return(par) # data were not standardised: fitted scale = original scale
  S <- diag(scale, nrow = length(scale))
  mu <- sweep(par$mu %*% S, 2, center, '+'); colnames(mu) <- colnames(par$mu)
  Sigma <- lapply(par$Sigma, function(Sz) { So <- S %*% Sz %*% S; So <- (So + t(So)) / 2; dimnames(So) <- dimnames(Sz); So })
  list(pi = par$pi, mu = mu, Sigma = Sigma, Nk = par$Nk)
}
s5_uncertainty <- function(tau) {
  G <- ncol(tau); mx <- apply(tau, 1, max)
  ent <- if (G == 1L) rep(0, nrow(tau)) else -rowSums(ifelse(tau > 0, tau * log(tau), 0)) / log(G)
  data.frame(MAP_component = max.col(tau, ties.method = 'first'), max_posterior = mx, uncertainty = 1 - mx, entropy_normalized = pmin(pmax(ent, 0), 1))
}
s5_cor <- function(S) { d <- sqrt(diag(S)); R <- S / outer(d, d); diag(R) <- 1; R }

s5_component_table <- function(par, tau, unc, amb_threshold) {
  G <- length(par$pi); n <- nrow(tau)
  data.frame(component = seq_len(G), mixing_proportion = par$pi, effective_n = colSums(tau),
             MAP_count = tabulate(unc$MAP_component, G), MAP_proportion = tabulate(unc$MAP_component, G) / n,
             mean_uncertainty_MAP = vapply(seq_len(G), function(i) if (any(unc$MAP_component == i)) mean(unc$uncertainty[unc$MAP_component == i]) else NA_real_, numeric(1)),
             mean_entropy_MAP = vapply(seq_len(G), function(i) if (any(unc$MAP_component == i)) mean(unc$entropy_normalized[unc$MAP_component == i]) else NA_real_, numeric(1)),
             n_ambiguous_MAP = vapply(seq_len(G), function(i) sum(unc$MAP_component == i & unc$uncertainty > amb_threshold), integer(1)))
}

# Descriptive phrases relative to the overall (original-scale) mean in overall-SD units. Generic: uses column names only.
s5_describe <- function(mu_o, overall_mean, overall_sd, comp, threshold = S5_THRESHOLDS$descriptor$value) {
  d <- (mu_o[comp, ] - overall_mean) / overall_sd
  hi <- names(d)[d >= threshold]; lo <- names(d)[d <= -threshold]; mid <- setdiff(names(d), c(hi, lo))
  f <- function(v) paste(sprintf('%s (%+.2f SD; mean %s)', v, d[v], formatC(mu_o[comp, v], format = 'fg', digits = 4)), collapse = ', ')
  c(if (length(hi)) paste('higher than the overall mean:', f(hi)), if (length(lo)) paste('lower than the overall mean:', f(lo)),
    if (length(mid)) paste('near the overall mean (|d| < ', threshold, ' SD): ', paste(mid, collapse = ', '), sep = ''))
}

# ---------------------------------------------------------------- plots (generic)
s5_palette <- function(G) if (G <= 8) c('#2F5D85', '#C65C48', '#3F8F5A', '#8E6BB5', '#C9962B', '#4BA3B5', '#B5577F', '#6E6E6E')[seq_len(G)] else hcl.colors(G, 'Dark 3')

s5_plot_profile_original <- function(par_o, feats, file) {
  G <- length(par_o$pi); p <- length(feats); col <- s5_palette(G); nc <- min(4L, p); nr <- ceiling(p / nc)
  png(file, width = 380 * nc + 60, height = 360 * nr + 90, res = 115); on.exit(dev.off())
  par(mfrow = c(nr, nc), mar = c(4, 4.6, 3, 1), oma = c(2.5, 0, 2.2, 0))
  for (v in feats) {
    m <- par_o$mu[, v]; s <- vapply(par_o$Sigma, function(S) sqrt(S[v, v]), numeric(1))
    yl <- range(m - s, m + s)
    plot(seq_len(G), m, ylim = yl, xlim = c(.5, G + .5), pch = 19, col = col, cex = 1.6, xaxt = 'n', xlab = 'Component', ylab = v, main = v)
    axis(1, at = seq_len(G)); arrows(seq_len(G), m - s, seq_len(G), m + s, angle = 90, code = 3, length = .05, col = col, lwd = 2)
  }
  mtext('Component means in original units (bars = +/- 1 within-component SD, sqrt of the covariance diagonal)', outer = TRUE, font = 2, cex = .9)
  mtext('Components are Gaussian mixture components, not verified groups.', side = 1, outer = TRUE, cex = .75, line = 1)
}
s5_plot_profile_std <- function(mu_o, overall_mean, overall_sd, file) {
  G <- nrow(mu_o); col <- s5_palette(G); d <- sweep(sweep(mu_o, 2, overall_mean, '-'), 2, overall_sd, '/'); p <- ncol(d)
  png(file, width = max(900, 160 * p + 300), height = 620, res = 115); on.exit(dev.off())
  par(mar = c(max(5, max(nchar(colnames(d))) * .5), 4.6, 3.5, 9), xpd = FALSE)
  plot(NA, xlim = c(1, max(2, p)), ylim = range(c(d, -.5, .5)), xaxt = 'n', xlab = '', ylab = '(component mean - overall mean) / overall SD',
       main = 'Standardised mean profile of components')
  abline(h = 0, col = 'grey60'); abline(h = c(-.5, .5), col = 'grey85', lty = 3)
  axis(1, at = seq_len(p), labels = colnames(d), las = 2, cex.axis = .85)
  for (i in seq_len(G)) lines(seq_len(p), d[i, ], type = 'b', pch = 19, col = col[i], lwd = 2)
  par(xpd = TRUE); legend(par('usr')[2] + .02 * diff(par('usr')[1:2]), par('usr')[4], paste('Component', seq_len(G)), col = col, lwd = 2, pch = 19, bty = 'n', cex = .85)
}
s5_plot_proportions <- function(ct, file) {
  G <- nrow(ct); col <- s5_palette(G)
  png(file, width = max(950, 170 * G + 300), height = 620, res = 115); on.exit(dev.off())
  par(mar = c(4.5, 4.6, 5, 1))
  m <- rbind(ct$mixing_proportion, ct$MAP_proportion)
  b <- barplot(m, beside = TRUE, names.arg = paste('Comp.', ct$component), col = c('grey45', 'grey80'), border = NA, ylim = c(0, max(m) * 1.3),
               ylab = 'Proportion', main = 'Mixing proportion (pi, model parameter)\nvs MAP classification proportion (hard assignments)', cex.main = 1)
  text(b[1, ], m[1, ], sprintf('%.3f', m[1, ]), pos = 3, cex = .8); text(b[2, ], m[2, ], sprintf('%.3f\n(n=%d)', m[2, ], ct$MAP_count), pos = 3, cex = .8)
  legend('topright', c('mixing proportion pi_i', 'MAP count / n'), fill = c('grey45', 'grey80'), border = NA, bty = 'n')
}
s5_plot_uncertainty <- function(unc, G, thr, file) {
  col <- s5_palette(G)
  png(file, width = 1300, height = 560, res = 115); on.exit(dev.off())
  par(mfrow = c(1, 2), mar = c(4.5, 4.6, 3.5, 1))
  hist(unc$uncertainty, breaks = seq(0, max(1 - 1 / G, 1e-9) + 1e-9, length.out = 31), col = 'grey70', border = 'white',
       xlab = 'U = 1 - max posterior', main = sprintf('Posterior uncertainty (n = %d; U > %.2f: %d)', nrow(unc), thr, sum(unc$uncertainty > thr)))
  abline(v = thr, lty = 2, col = '#C65C48')
  boxplot(uncertainty ~ factor(MAP_component, levels = seq_len(G)), data = unc, col = adjustcolor(col, .5), border = col,
          xlab = 'MAP component', ylab = 'U', main = 'Uncertainty by MAP component')
  abline(h = thr, lty = 2, col = '#C65C48')
}
s5_plot_cor_heatmaps <- function(par, feats, file) {
  G <- length(par$pi); p <- length(feats); nc <- min(3L, G); nr <- ceiling(G / nc)
  pal <- colorRampPalette(c('#2B6CB0', '#F7F7F7', '#C53030'))(201)
  png(file, width = max(560, 70 * p + 300) * nc, height = (max(520, 65 * p + 300)) * nr, res = 115); on.exit(dev.off())
  par(mfrow = c(nr, nc), mar = c(max(5, max(nchar(feats)) * .55), max(5, max(nchar(feats)) * .55), 3, 1))
  for (i in seq_len(G)) {
    R <- s5_cor(par$Sigma[[i]])
    image(seq_len(p), seq_len(p), t(R[p:1, , drop = FALSE]), zlim = c(-1, 1), col = pal, axes = FALSE, xlab = '', ylab = '',
          main = sprintf('Component %d (pi = %.3f)', i, par$pi[i]))
    axis(1, seq_len(p), feats, las = 2, cex.axis = .8); axis(2, seq_len(p), rev(feats), las = 1, cex.axis = .8)
    for (a in seq_len(p)) for (b in seq_len(p)) text(b, p + 1 - a, sprintf('%.2f', R[a, b]), cex = if (p > 6) .65 else .9)
    box()
  }
}
s5_plot_pca <- function(X, par, unc, file) {
  G <- length(par$pi); col <- s5_palette(G)
  pc <- prcomp(X, center = TRUE, scale. = FALSE); W <- pc$rotation[, 1:min(2, ncol(X)), drop = FALSE]
  sc <- pc$x[, 1:ncol(W), drop = FALSE]; if (ncol(sc) == 1) { sc <- cbind(sc, 0); W <- cbind(W, 0) }
  ve <- pc$sdev^2 / sum(pc$sdev^2)
  png(file, width = 1100, height = 900, res = 120); on.exit(dev.off())
  par(mar = c(5, 5, 5, 1))
  rgbm <- col2rgb(col[unc$MAP_component]) / 255
  alpha <- .35 + .6 * (1 - unc$uncertainty / max(1e-12, 1 - 1 / G)) # more certain -> more opaque
  pcol <- rgb(rgbm[1, ], rgbm[2, ], rgbm[3, ], pmin(1, pmax(.2, alpha)))
  plot(sc, col = pcol, pch = ifelse(unc$uncertainty > S5_THRESHOLDS$ambiguous$value, 1, 16),
       xlab = sprintf('PC1 (%.1f%% of variance)', 100 * ve[1]), ylab = sprintf('PC2 (%.1f%% of variance)', 100 * if (length(ve) > 1) ve[2] else 0),
       main = 'PCA projection of the analysis matrix, coloured by MAP component\n(visualisation only: the GMM was estimated in the full p-dimensional space, not on these 2 PCs)', cex.main = .95)
  tt <- seq(0, 2 * pi, length.out = 200)
  for (i in seq_len(G)) {
    m2 <- as.numeric(crossprod(W, par$mu[i, ] - pc$center)); S2 <- t(W) %*% par$Sigma[[i]] %*% W
    e <- eigen(S2, symmetric = TRUE); r <- sqrt(qchisq(.95, 2)) * e$vectors %*% diag(sqrt(pmax(e$values, 0))) %*% rbind(cos(tt), sin(tt))
    lines(m2[1] + r[1, ], m2[2] + r[2, ], col = col[i], lwd = 2); points(m2[1], m2[2], pch = 4, cex = 2, lwd = 3, col = col[i])
  }
  legend('topright', c(paste('Component', seq_len(G)), sprintf('open circle: U > %.2f', S5_THRESHOLDS$ambiguous$value), 'ellipse: projected 95% component region'),
         col = c(col, 'black', 'black'), pch = c(rep(16, G), 1, NA), lty = c(rep(NA, G), NA, 1), bg = adjustcolor('white', .85), box.col = 'grey80', cex = .8)
  list(variance_explained = ve[1:min(2, length(ve))])
}

# ---------------------------------------------------------------- end-to-end
stage5_interpret <- function(stage4_dir, data, spec, output, transform = NULL, ambiguity_threshold = S5_THRESHOLDS$ambiguous$value, config_file = NULL) {
  s4 <- resolve_path(stage4_dir); output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory. Use e.g. results/<name>.')
  if (file.exists(output_path) && !dir.exists(output_path)) fail('Output path exists and is a file: ', output_path)
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) {
    fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  }
  need <- file.path(s4, c('selected_model.rds', 'posterior_selected.csv', 'selected_model.json', 'model_comparison.csv'))
  if (any(!file.exists(need))) fail('Stage 4 selection directory is missing: ', paste(basename(need[!file.exists(need)]), collapse = ', '))
  d <- s4_like_read(data, spec)
  rd <- readRDS(need[1]); sj <- jsonlite::fromJSON(need[3], simplifyVector = TRUE); mc <- read.csv(need[4])
  post <- read.csv(need[2], check.names = FALSE)
  if (!identical(rd$spec_hash, d$sp$spec_hash) || !identical(sj$spec$spec_hash, d$sp$spec_hash)) fail('Stage 4 model was fitted under a different Stage 3 spec (spec_hash mismatch).')
  if (!identical(rd$features, d$feats)) fail('Stage 4 model features differ from the approved spec.')
  G <- rd$G; par <- rd$par; X <- d$X; n <- nrow(X); feats <- d$feats
  idn <- if (is.null(d$idc)) 'row_id' else d$idc
  # When the data have no ID column, Stage 3 records id_column = "(row number)" and Stage 4 uses that header; IDs are row numbers.
  pid <- if (idn %in% names(post)) post[[idn]] else if (is.null(d$idc) && identical(names(post)[1], d$sp$id_column)) post[[1]] else NULL
  if (!identical(as.numeric(pid), as.numeric(d$ids))) fail('posterior_selected.csv row IDs do not match the analysis data.')
  tau_s <- as.matrix(post[, paste0('tau_', seq_len(G)), drop = FALSE])
  # (1) the stored posterior must be reproduced by the stored parameters in the same component order (label consistency)
  e <- em_estep(X, par)
  if (!e$ok) fail('Selected parameters cannot be evaluated: ', e$reason)
  d_post <- max(abs(e$tau - tau_s))
  if (d_post > S5_THRESHOLDS$posterior_reproduction$value) fail(sprintf('posterior_selected.csv does not match the selected parameters (max diff %.3g): component labels or files are inconsistent.', d_post))
  if (abs(e$loglik - rd$loglik) > 1e-6 * (1 + abs(rd$loglik))) fail('Stored log-likelihood does not match the selected parameters.')
  # (2) back-transformation
  zscored <- identical(d$sp$scale$method, 'zscore')
  center <- NULL; scl <- NULL; tp_path <- NULL
  if (zscored) {
    if (is.null(transform)) fail('The approved scale is zscore: provide --transform (Stage 3 transform_params.csv).')
    tp_path <- resolve_path(transform); if (!file.exists(tp_path)) fail('transform_params.csv not found: ', tp_path)
    tp <- read.csv(tp_path); tp <- tp[match(feats, tp$variable), ]
    if (any(is.na(tp$variable))) fail('transform_params.csv lacks some features.')
    center <- setNames(tp$center, feats); scl <- setNames(tp$scale, feats)
    sp_c <- unlist(d$sp$scale$parameters$center)[feats]; sp_s <- unlist(d$sp$scale$parameters$scale)[feats]
    if (max(abs(center - sp_c)) > 1e-9 * (1 + max(abs(sp_c))) || max(abs(scl - sp_s)) > 1e-9 * (1 + max(abs(sp_s)))) fail('transform_params.csv differs from the approved Stage 3 spec.')
  } else if (!is.null(transform)) fail('The approved scale is "none": the fitted parameters are already in original units; do not pass --transform.')
  par_o <- s5_back_transform(par, center, scl)
  Xo <- if (zscored) sweep(sweep(X, 2, scl, '*'), 2, center, '+') else X
  e_o <- em_estep(Xo, par_o)
  d_inv <- max(abs(e_o$tau - e$tau))
  if (d_inv > S5_THRESHOLDS$invariance$value) fail(sprintf('Posterior probabilities change under back-transformation (max diff %.3g).', d_inv))
  d_cor <- max(vapply(seq_len(G), function(i) max(abs(s5_cor(par_o$Sigma[[i]]) - s5_cor(par$Sigma[[i]]))), numeric(1)))
  loglik_shift <- if (zscored) -n * sum(log(scl)) else 0 # log-lik on original scale = fitted + n * (-log|S|)
  # (3) classification / uncertainty
  unc <- s5_uncertainty(e$tau)
  ct <- s5_component_table(par, e$tau, unc, ambiguity_threshold)
  overall_mean <- colMeans(Xo); overall_sd <- apply(Xo, 2, sd)
  descr <- lapply(seq_len(G), function(i) s5_describe(par_o$mu, overall_mean, overall_sd, i))
  sd_o <- t(vapply(par_o$Sigma, function(S) sqrt(diag(S)), numeric(length(feats)))); if (G == 1) sd_o <- matrix(sd_o, nrow = 1)
  colnames(sd_o) <- feats
  means_tab <- rbind(data.frame(scale = 'original', component = seq_len(G), par_o$mu, check.names = FALSE),
                     data.frame(scale = if (zscored) 'fitted (z-score)' else 'fitted (= original)', component = seq_len(G), par$mu, check.names = FALSE))
  sd_tab <- data.frame(component = seq_len(G), sd_o, check.names = FALSE)
  cov_long <- do.call(rbind, lapply(seq_len(G), function(i) {
    g <- expand.grid(var1 = feats, var2 = feats, stringsAsFactors = FALSE)
    data.frame(component = i, g, covariance_original = as.vector(par_o$Sigma[[i]][cbind(match(g$var1, feats), match(g$var2, feats))]),
               covariance_fitted = as.vector(par$Sigma[[i]][cbind(match(g$var1, feats), match(g$var2, feats))]),
               correlation = as.vector(s5_cor(par$Sigma[[i]])[cbind(match(g$var1, feats), match(g$var2, feats))]),
               units_original = paste0('(', g$var1, ' unit) x (', g$var2, ' unit)'))
  }))
  cls <- data.frame(d$ids, e$tau, unc, ambiguous = unc$uncertainty > ambiguity_threshold); names(cls) <- c(idn, paste0('tau_', seq_len(G)), names(unc), 'ambiguous')
  amb <- cls[cls$ambiguous, , drop = FALSE]
  if (nrow(amb) && G > 1) {
    top2 <- t(apply(e$tau[cls$ambiguous, , drop = FALSE], 1, function(r) { o <- order(-r)[1:2]; c(o, r[o]) }))
    amb <- data.frame(amb[, idn, drop = FALSE], MAP_component = top2[, 1], tau_MAP = top2[, 3], second_component = top2[, 2], tau_second = top2[, 4],
                      uncertainty = amb$uncertainty, entropy_normalized = amb$entropy_normalized, Xo[cls$ambiguous, , drop = FALSE], check.names = FALSE)
    amb <- amb[order(-amb$uncertainty), ]
  }
  unc_sum <- list(n = n, G = G, threshold_ambiguous = ambiguity_threshold,
                  overall = list(mean_U = mean(unc$uncertainty), median_U = median(unc$uncertainty), max_U = max(unc$uncertainty),
                                 quantiles_U = as.list(quantile(unc$uncertainty, c(.5, .75, .9, .95, .99))),
                                 mean_entropy_normalized = mean(unc$entropy_normalized),
                                 n_U_gt = list(`0.01` = sum(unc$uncertainty > .01), `0.05` = sum(unc$uncertainty > .05), `0.10` = sum(unc$uncertainty > .10), `0.25` = sum(unc$uncertainty > .25))),
                  by_MAP_component = lapply(seq_len(G), function(i) list(component = i, n = ct$MAP_count[i], mean_U = ct$mean_uncertainty_MAP[i],
                                                                        mean_entropy = ct$mean_entropy_MAP[i], n_ambiguous = ct$n_ambiguous_MAP[i])),
                  max_U_possible = 1 - 1 / G,
                  note = 'Posterior probabilities are model-based membership probabilities under the fitted mixture; they are not verified classification accuracy.')
  aic_G <- mc$G[mc$selected_AIC %in% TRUE]; bic_G <- sj$selected_G
  comp_note <- c(sprintf('BIC selected G = %d (Stage 4D).', bic_G),
                 if (length(aic_G) && aic_G != bic_G) sprintf('AIC preferred G = %d; G = %d is retained for Stage 6 sensitivity analysis (not interpreted here).', aic_G, aic_G)
                 else 'AIC agrees with BIC.',
                 if (length(sj$alternatives_for_stage6)) sprintf('BIC alternatives (delta BIC <= 6) for Stage 6: G = %s.', paste(sj$alternatives_for_stage6, collapse = ', ')))
  checks <- list(posterior_reproduced = list(max_abs_diff = d_post, pass = TRUE), loglik_reproduced = list(pass = TRUE),
                 backtransform_posterior_invariance = list(max_abs_diff = d_inv, pass = TRUE),
                 correlation_invariance = list(max_abs_diff = d_cor, pass = d_cor < 1e-10),
                 component_order = 'as in Stage 4 selected_model (decreasing mixing proportion); identical in every output',
                 loglik_original_scale = rd$loglik + loglik_shift, loglik_fitted_scale = rd$loglik)
  summary <- list(stage = 5, script_version = S5_VERSION, generated_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
    stage4_dir = s4, spec = list(spec_hash = d$sp$spec_hash, approval_id = d$sp$approval_id), selected_G = G, covariance = 'full, component-specific (VVV)',
    scale = list(fitted = d$sp$scale$method, back_transform = if (zscored) 'mu_o = m + S mu_z; Sigma_o = S Sigma_z S (S = diag(sd))' else 'none needed', transform_params = tp_path),
    features = I(feats), n = n, checks = checks, model_selection_notes = I(comp_note),
    components = lapply(seq_len(G), function(i) list(component = i, mixing_proportion = par$pi[i], effective_n = ct$effective_n[i], MAP_count = ct$MAP_count[i],
                                                     MAP_proportion = ct$MAP_proportion[i], mean_original = as.list(par_o$mu[i, ]), sd_original = as.list(sd_o[i, ]),
                                                     description = I(descr[[i]]))),
    uncertainty = unc_sum, thresholds = S5_THRESHOLDS,
    carried_warnings = list(independence = list(status = d$sp$rows_independent, note = d$sp$independence_note), outlier_policy = d$sp$outlier_policy,
                            external_label = 'not used in Stage 5 (no naming of components by external labels)',
                            components_vs_groups = 'Gaussian components are not necessarily real or natural groups.'),
    not_done = 'Stage 6 (external validation, stability, sensitivity) not performed', output_dir = output_path)
  run_config <- list(script_version = S5_VERSION, stage4_dir = s4, data = d$input_path, spec = d$spec_path, transform = tp_path, output = output_path,
                     ambiguity_threshold = ambiguity_threshold, config_file = if (!is.null(config_file)) resolve_path(config_file) else NULL, r_version = R.version.string)
  required <- c('stage5_summary.json', 'component_summary.csv', 'component_means.csv', 'component_sd_original.csv', 'component_covariances.csv',
                'classification.csv', 'ambiguous_observations.csv', 'uncertainty_summary.json', 'stage5_parameters_original.json', 'stage5_report.md',
                'mean_profile_original.png', 'mean_profile_standardized.png', 'proportions_map.png', 'uncertainty.png', 'correlation_heatmaps.png',
                'pca_projection.png', 'run_config.json')
  pca_info <- NULL
  writer <- function(dir) {
    write.csv(ct, file.path(dir, 'component_summary.csv'), row.names = FALSE)
    write.csv(means_tab, file.path(dir, 'component_means.csv'), row.names = FALSE)
    write.csv(sd_tab, file.path(dir, 'component_sd_original.csv'), row.names = FALSE)
    write.csv(cov_long, file.path(dir, 'component_covariances.csv'), row.names = FALSE)
    write.csv(cls, file.path(dir, 'classification.csv'), row.names = FALSE)
    write.csv(amb, file.path(dir, 'ambiguous_observations.csv'), row.names = FALSE)
    write_json_file(unc_sum, file.path(dir, 'uncertainty_summary.json'))
    write_json_file(list(G = G, features = I(feats), scale = 'original units', pi = par_o$pi,
                         mu = lapply(seq_len(G), function(i) as.list(par_o$mu[i, ])), Sigma = lapply(par_o$Sigma, unname),
                         correlation = lapply(par_o$Sigma, function(S) unname(s5_cor(S)))), file.path(dir, 'stage5_parameters_original.json'))
    s5_plot_profile_original(par_o, feats, file.path(dir, 'mean_profile_original.png'))
    s5_plot_profile_std(par_o$mu, overall_mean, overall_sd, file.path(dir, 'mean_profile_standardized.png'))
    s5_plot_proportions(ct, file.path(dir, 'proportions_map.png'))
    s5_plot_uncertainty(unc, G, ambiguity_threshold, file.path(dir, 'uncertainty.png'))
    s5_plot_cor_heatmaps(par, feats, file.path(dir, 'correlation_heatmaps.png'))
    pca_info <<- s5_plot_pca(X, par, unc, file.path(dir, 'pca_projection.png'))
    summary$pca_visualisation <- list(variance_explained_PC1_PC2 = pca_info$variance_explained, basis = 'PCA of the analysis (fitted-scale) matrix; for display only')
    write_json_file(summary, file.path(dir, 'stage5_summary.json'))
    write_json_file(run_config, file.path(dir, 'run_config.json'))
    writeLines(s5_report_md(summary, ct, par, par_o, sd_o, unc_sum, amb, idn, pca_info), file.path(dir, 'stage5_report.md'), useBytes = TRUE)
  }
  validator <- function(dir) {
    bad <- required[!file.exists(file.path(dir, required))]
    if (length(bad)) fail('Staged Stage 5 output incomplete: ', paste(bad, collapse = ', '))
    cc <- read.csv(file.path(dir, 'classification.csv'))
    if (nrow(cc) != n || max(abs(rowSums(cc[, paste0('tau_', seq_len(G)), drop = FALSE]) - 1)) > 1e-8) fail('classification.csv failed validation.')
  }
  stage_and_commit(output_path, writer, validator)
  invisible(list(summary = summary, component_table = ct, par_original = par_o, par_fitted = par, uncertainty = unc, classification = cls,
                 ambiguous = amb, output_dir = output_path))
}

# Approved-data reader (same checks as Stage 4).
s4_like_read <- function(input, spec) {
  spec_path <- resolve_path(spec); input_path <- resolve_path(input)
  if (!file.exists(spec_path)) fail('Stage 3 spec not found: ', spec_path)
  if (!file.exists(input_path)) fail('Analysis data not found: ', input_path)
  sp <- jsonlite::fromJSON(spec_path, simplifyVector = TRUE)
  if (!isTRUE(sp$approved_for_fit)) fail('Stage 3 spec is not approved.')
  raw <- read.csv(input_path, check.names = FALSE); feats <- sp$features; idc <- sp$id_column
  if (!all(feats %in% names(raw))) fail('Analysis data lack approved features.')
  if (nrow(raw) != sp$input$n_rows) fail('Analysis data row count differs from the approved spec.')
  ids <- if (!is.null(idc) && idc %in% names(raw)) raw[[idc]] else seq_len(nrow(raw))
  if (!identical(em_hash_ids(ids), sp$row_ids_md5)) fail('Row IDs differ from the approved Stage 3 specification.')
  X <- as.matrix(raw[, feats])
  if (identical(sp$scale$method, 'zscore') && (any(abs(colMeans(X)) > 1e-6) || any(abs(apply(X, 2, sd) - 1) > 1e-6))) fail('Analysis data are not the approved z-scored matrix.')
  list(X = X, ids = ids, sp = sp, idc = if (!is.null(idc) && idc %in% names(raw)) idc else NULL, feats = feats, spec_path = spec_path, input_path = input_path)
}

s5_report_md <- function(s, ct, par, par_o, sd_o, us, amb, idn, pca) {
  G <- s$selected_G; feats <- s$features; fm <- function(x) formatC(x, format = 'fg', digits = 4)
  L <- c('# Stage 5 - Interpretation of the selected Gaussian mixture', '',
         sprintf('- Selected model: **G = %d**, %s; n = %d, features: %s', G, s$covariance, s$n, paste(feats, collapse = ', ')),
         sprintf('- Spec `%s` (approval `%s`); fitted scale: %s; back-transformation: %s', s$spec$spec_hash, s$spec$approval_id, s$scale$fitted, s$scale$back_transform),
         sprintf('- Checks: stored posterior reproduced (max diff %.2g); posterior invariant under back-transformation (max diff %.2g); correlations invariant (max diff %.2g).',
                 s$checks$posterior_reproduced$max_abs_diff, s$checks$backtransform_posterior_invariance$max_abs_diff, s$checks$correlation_invariance$max_abs_diff),
         paste('- Model selection context:', paste(s$model_selection_notes, collapse = ' ')),
         '- Component labels follow the Stage 4 order (decreasing mixing proportion) in every table and figure.', '',
         '## Cautions', '',
         '- A Gaussian component is a density component; it is **not necessarily** a real-world group, predefined class or natural group, and components are not named here.',
         '- External labels were not used in this stage. Posterior probabilities are model-based membership probabilities, **not** verified classification accuracy.',
         sprintf('- Independence: %s. %s', s$carried_warnings$independence$status, if (is.null(s$carried_warnings$independence$note)) '' else s$carried_warnings$independence$note),
         sprintf('- Outliers: %s.', s$carried_warnings$outlier_policy),
         '', '## Mixing proportions vs MAP classification', '',
         paste('The mixing proportion pi_i is a model parameter (prior weight of component i). The effective size is sum_j tau_ji at the final parameters; it equals n * pi_i at an exact EM fixed point, so the two agree to the convergence tolerance.',
               'The MAP proportion counts hard assignments and can differ from pi_i when components overlap.'), '',
         '| Component | mixing proportion pi | effective n (sum tau) | MAP count | MAP proportion | mean U (MAP) | ambiguous (U > threshold) |', '|---|---|---|---|---|---|---|',
         sprintf('| %d | %.4f | %.1f | %d | %.4f | %.4f | %d |', ct$component, ct$mixing_proportion, ct$effective_n, ct$MAP_count, ct$MAP_proportion,
                 ct$mean_uncertainty_MAP, ct$n_ambiguous_MAP),
         '', '## Component means and within-component SD (original units)', '',
         paste0('| Component | ', paste(feats, collapse = ' | '), ' |'), paste0('|---|', strrep('---|', length(feats))))
  for (i in seq_len(G)) L <- c(L, paste0('| ', i, ' | ', paste(sprintf('%s (SD %s)', fm(par_o$mu[i, ]), fm(sd_o[i, ])), collapse = ' | '), ' |'))
  L <- c(L, '', '## Component descriptions (generated from the estimated parameters)', '')
  for (cp in s$components) {
    L <- c(L, sprintf('**Component %d** (pi = %.3f, MAP n = %d):', cp$component, cp$mixing_proportion, cp$MAP_count), paste('-', cp$description))
    R <- s5_cor(par$Sigma[[cp$component]]); if (length(feats) > 1) {
      ut <- which(upper.tri(R), arr.ind = TRUE); k <- ut[which.max(abs(R[ut])), ]
      L <- c(L, sprintf('- strongest within-component correlation: %s ~ %s, r = %.2f', feats[k[1]], feats[k[2]], R[k[1], k[2]]))
    }
    L <- c(L, '')
  }
  L <- c(L, '## Posterior uncertainty', '',
         sprintf('- U_j = 1 - max_i tau_ji (maximum possible %.3f for G = %d). Mean U = %.4f, median = %.2g, max = %.4f; normalized entropy mean = %.4f.',
                 us$max_U_possible, G, us$overall$mean_U, us$overall$median_U, us$overall$max_U, us$overall$mean_entropy_normalized),
         sprintf('- Observations with U > 0.01: %d; > 0.05: %d; > 0.10: %d; > 0.25: %d (of %d).', us$overall$n_U_gt$`0.01`, us$overall$n_U_gt$`0.05`,
                 us$overall$n_U_gt$`0.10`, us$overall$n_U_gt$`0.25`, us$n),
         sprintf('- Ambiguous observations (U > %.2f) are listed in `ambiguous_observations.csv`; they are not removed or reclassified.', us$threshold_ambiguous))
  if (nrow(amb) && G > 1) {
    top <- head(amb, 15)
    L <- c(L, '', sprintf('| %s | MAP | tau(MAP) | second | tau(second) | U |', idn), '|---|---|---|---|---|---|',
           sprintf('| %s | %d | %.3f | %d | %.3f | %.3f |', top[[idn]], top$MAP_component, top$tau_MAP, top$second_component, top$tau_second, top$uncertainty))
  }
  L <- c(L, '', '## Figures', '',
         '- `mean_profile_original.png`: component means in original units with +/- 1 within-component SD.',
         '- `mean_profile_standardized.png`: component means relative to the overall mean in overall-SD units.',
         '- `proportions_map.png`: mixing proportions vs MAP proportions.',
         '- `uncertainty.png`: distribution of U overall and by MAP component.',
         '- `correlation_heatmaps.png`: within-component correlation matrices (scale-free).',
         sprintf('- `pca_projection.png`: PCA projection (PC1 %.1f%%, PC2 %.1f%% of variance) coloured by MAP, with projected 95%% component ellipses. **Visualisation only**: the GMM was estimated in all %d dimensions, not on the principal components.',
                 100 * pca$variance_explained[1], 100 * if (length(pca$variance_explained) > 1) pca$variance_explained[2] else 0, length(feats)),
         '', '## Not done in Stage 5', '', '- No refitting, no re-selection, no use of external labels, no stability or sensitivity analysis (Stage 6).')
  enc2utf8(L)
}

s5_cli <- function(argv) {
  keys <- c('stage4-dir', 'data', 'spec', 'transform', 'output', 'ambiguity-threshold', 'config')
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
    for (k in names(cfg)) if (is.null(a[[k]])) a[[k]] <- as.character(cfg[[k]])
  }
  miss <- setdiff(c('stage4-dir', 'data', 'spec', 'output'), names(a)); if (length(miss)) fail('Missing settings: ', paste(miss, collapse = ', '))
  thr <- if (is.null(a[['ambiguity-threshold']])) S5_THRESHOLDS$ambiguous$value else as.numeric(a[['ambiguity-threshold']])
  if (!is.finite(thr) || thr <= 0 || thr >= 1) fail('ambiguity-threshold must be in (0, 1).')
  stage5_interpret(a[['stage4-dir']], a$data, a$spec, a$output, transform = a$transform, ambiguity_threshold = thr, config_file = a$config)
}

if (sys.nframe() == 0L) {
  r <- tryCatch(s5_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
  print(format(r$component_table, digits = 4), row.names = FALSE)
  cat(sprintf('Mean uncertainty %.4f; ambiguous (U > %.2f): %d\n', r$summary$uncertainty$overall$mean_U, r$summary$uncertainty$threshold_ambiguous, nrow(r$ambiguous)))
  cat('Output directory:', r$output_dir, '\n')
}
