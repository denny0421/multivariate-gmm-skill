# Stage 2 exploratory data analysis (EDA) for continuous numeric features.
# Generic: works on any data.frame of numeric columns; no variable names are hard-coded.
# Read-only: never deletes or imputes. Univariate statistics use each variable's observed values
# (available-case); correlations use pairwise-complete pairs; collinearity diagnostics use rows
# complete on all features. Any external label is NEVER used in statistics or plots.
#
# Sourced by data_stage2.R. Main entry: stage2_eda(x, dir, title = NULL)
# Runtime dependency: jsonlite + base R graphics.

EDA_SCATTER_MAX_VARS <- 12L        # scatterplot matrix skipped above this (unreadable)
EDA_FLAG_ABS_R <- 0.90             # heuristic flags, not textbook thresholds
EDA_FLAG_CONDITION <- 30
EDA_FLAG_VIF <- 10
EDA_FILES <- c('descriptive_stats.csv', 'correlation_pearson.csv', 'correlation_spearman.csv',
               'correlation_pairwise_n.csv', 'correlation_pairs.csv', 'collinearity.json',
               'distributions.png', 'boxplots.png', 'correlation_heatmap.png', 'eda_summary.json')

eda_skew <- function(o) { if (length(o) < 3L) return(NA_real_); m <- mean(o); s2 <- mean((o - m)^2); if (s2 == 0) NA_real_ else mean((o - m)^3) / s2^1.5 }
eda_exkurt <- function(o) { if (length(o) < 4L) return(NA_real_); m <- mean(o); s2 <- mean((o - m)^2); if (s2 == 0) NA_real_ else mean((o - m)^4) / s2^2 - 3 }
eda_breaks <- function(o) {
  if (length(unique(o)) < 2L) return(1L)
  if (IQR(o) > 0) 'FD' else 'Sturges'
}

stage2_descriptives <- function(x) {
  do.call(rbind, lapply(names(x), function(f) {
    v <- x[[f]]; o <- v[!is.na(v)]; n <- length(o)
    if (!n) {
      return(data.frame(variable = f, n_observed = 0L, n_missing = length(v), mean = NA, sd = NA, cv = NA, min = NA,
                        q1 = NA, median = NA, q3 = NA, max = NA, iqr = NA, skewness = NA, excess_kurtosis = NA,
                        n_iqr_outliers = NA, n_abs_z_gt3 = NA, n_unique = 0L, zero_variance = NA))
    }
    q <- quantile(o, c(.25, .5, .75), names = FALSE); iqr <- q[3] - q[1]
    s <- if (n > 1L) sd(o) else NA_real_
    z <- if (isTRUE(s > 0)) (o - mean(o)) / s else rep(0, n)
    data.frame(variable = f, n_observed = n, n_missing = sum(is.na(v)), mean = mean(o), sd = s,
               cv = if (isTRUE(mean(o) != 0) && !is.na(s)) s / mean(o) else NA_real_,
               min = min(o), q1 = q[1], median = q[2], q3 = q[3], max = max(o), iqr = iqr,
               skewness = eda_skew(o), excess_kurtosis = eda_exkurt(o),
               n_iqr_outliers = sum(o < q[1] - 1.5 * iqr | o > q[3] + 1.5 * iqr), n_abs_z_gt3 = sum(abs(z) > 3),
               n_unique = length(unique(o)), zero_variance = isTRUE(s == 0) || n == 1L)
  }))
}

stage2_correlations <- function(x) {
  m <- as.matrix(x)
  pear <- suppressWarnings(cor(m, use = 'pairwise.complete.obs', method = 'pearson'))
  spear <- suppressWarnings(cor(m, use = 'pairwise.complete.obs', method = 'spearman'))
  pair_n <- crossprod(!is.na(m)); storage.mode(pair_n) <- 'integer'
  vars <- names(x)
  pairs <- do.call(rbind, combn(seq_along(vars), 2L, function(ij) {
    a <- m[, ij[1]]; b <- m[, ij[2]]; k <- !is.na(a) & !is.na(b); n <- sum(k)
    ci <- c(NA_real_, NA_real_); r <- NA_real_; p <- NA_real_
    if (n >= 3L && sd(a[k]) > 0 && sd(b[k]) > 0) {
      r <- cor(a[k], b[k])
      if (n >= 4L) { ct <- cor.test(a[k], b[k]); ci <- ct$conf.int[1:2]; p <- ct$p.value }
    }
    data.frame(var1 = vars[ij[1]], var2 = vars[ij[2]], n_pairwise = n, pearson_r = r, ci95_low = ci[1],
               ci95_high = ci[2], p_value = p, spearman_rho = spear[ij[1], ij[2]])
  }, simplify = FALSE))
  list(pearson = pear, spearman = spear, pair_n = pair_n, pairs = pairs)
}

stage2_collinearity <- function(x, desc) {
  cc <- x[complete.cases(x), , drop = FALSE]
  zero <- desc$variable[desc$zero_variance %in% TRUE]
  out <- list(basis = 'rows complete on all selected features', n_complete_rows = nrow(cc),
              zero_variance_columns = I(zero), correlation_eigenvalues = NULL, condition_number = NULL,
              full_rank = NULL, vif = NULL, high_correlation_pairs = I(character()), flags = I(character()),
              thresholds = list(abs_r = EDA_FLAG_ABS_R, condition_number = EDA_FLAG_CONDITION, vif = EDA_FLAG_VIF,
                                note = 'Heuristic screening flags (project choices), not textbook cut-offs.'))
  flags <- character()
  if (length(zero)) flags <- c(flags, paste('ZERO_VARIANCE:', paste(zero, collapse = ', ')))
  usable <- setdiff(names(x), zero)
  if (nrow(cc) <= length(usable)) flags <- c(flags, 'TOO_FEW_COMPLETE_ROWS_FOR_RANK_CHECK')
  if (length(usable) >= 2L && nrow(cc) > length(usable)) {
    r <- cor(cc[, usable, drop = FALSE])
    ev <- eigen(r, symmetric = TRUE, only.values = TRUE)$values
    out$correlation_eigenvalues <- ev
    out$full_rank <- min(ev) > 1e-8 * max(ev) && !length(zero)
    out$condition_number <- if (min(ev) > 0) sqrt(max(ev) / min(ev)) else Inf
    if (!out$full_rank) flags <- c(flags, 'RANK_DEFICIENT')
    if (out$condition_number > EDA_FLAG_CONDITION) flags <- c(flags, 'HIGH_CONDITION_NUMBER')
    inv <- tryCatch(solve(r), error = function(e) NULL)
    if (!is.null(inv)) {
      out$vif <- as.list(setNames(diag(inv), usable))
      hv <- usable[diag(inv) > EDA_FLAG_VIF]
      if (length(hv)) flags <- c(flags, paste('HIGH_VIF:', paste(hv, collapse = ', ')))
    }
    hp <- which(abs(r) > EDA_FLAG_ABS_R & upper.tri(r), arr.ind = TRUE)
    if (nrow(hp)) {
      out$high_correlation_pairs <- I(sprintf('%s~%s (r=%.3f)', usable[hp[, 1]], usable[hp[, 2]], r[hp]))
      flags <- c(flags, 'HIGH_PAIRWISE_CORRELATION')
    }
  } else if (length(names(x)) >= 2L && !length(zero) && nrow(cc) <= length(usable)) {
    out$full_rank <- FALSE
  }
  out$flags <- I(flags)
  out
}

eda_grid <- function(p) { nc <- ceiling(sqrt(p)); c(ceiling(p / nc), nc) }

stage2_eda_plots <- function(x, cors, dir, title) {
  vars <- names(x); p <- length(vars); suffix <- if (is.null(title)) '' else paste0(' - ', title)
  ink <- '#2F5D85'; soft <- '#A9C3DA'; warm <- '#C65C48'
  files <- character()

  png(file.path(dir, 'distributions.png'), width = 450 * eda_grid(p)[2] + 100, height = 380 * eda_grid(p)[1] + 80, res = 120)
  tryCatch({
    par(mfrow = eda_grid(p), mar = c(4.2, 4.2, 3.2, 1), oma = c(0, 0, 2, 0))
    for (f in vars) {
      o <- x[[f]][!is.na(x[[f]])]
      if (length(o) < 2L) { plot.new(); title(f); text(.5, .5, 'fewer than 2 observed values'); next }
      h <- hist(o, breaks = eda_breaks(o), plot = FALSE)
      d <- if (length(unique(o)) > 1L) density(o) else NULL
      ymax <- max(h$density, if (!is.null(d)) d$y else 0) * 1.08
      hist(o, breaks = h$breaks, freq = FALSE, col = soft, border = 'white', main = f, xlab = f, ylim = c(0, ymax))
      if (!is.null(d)) lines(d, col = ink, lwd = 2)
      rug(o, col = adjustcolor(ink, .4))
      mtext(sprintf('n = %d, skew = %s', length(o), formatC(eda_skew(o), format = 'f', digits = 2)), side = 3, line = .2, cex = .75)
    }
    mtext(paste0('Distributions (observed values)', suffix), outer = TRUE, font = 2)
  }, finally = dev.off())

  png(file.path(dir, 'boxplots.png'), width = max(700, 300 * p), height = 700, res = 120)
  tryCatch({
    par(mfrow = c(1, p), mar = c(3, 4.2, 3, 1), oma = c(0, 0, 2, 0))
    for (f in vars) {
      o <- x[[f]][!is.na(x[[f]])]
      if (!length(o)) { plot.new(); title(f); next }
      boxplot(o, col = soft, border = ink, main = f, outcol = warm, pch = 16)
    }
    mtext(paste0('Boxplots (1.5 x IQR whiskers; red = beyond whiskers)', suffix), outer = TRUE, font = 2)
  }, finally = dev.off())

  scatter_done <- FALSE
  if (p <= EDA_SCATTER_MAX_VARS) {
    png(file.path(dir, 'scatter_matrix.png'), width = 360 * p + 150, height = 360 * p + 150, res = 120)
    tryCatch({
      panel_hist <- function(v, ...) {
        o <- v[!is.na(v)]; if (length(o) < 2L) return(invisible())
        usr <- par('usr'); on.exit(par(usr = usr)); h <- hist(o, breaks = eda_breaks(o), plot = FALSE)
        par(usr = c(usr[1:2], 0, max(h$counts) * 1.5))
        rect(h$breaks[-length(h$breaks)], 0, h$breaks[-1], h$counts, col = soft, border = 'white')
      }
      panel_cor <- function(a, b, ...) {
        usr <- par('usr'); on.exit(par(usr = usr)); par(usr = c(0, 1, 0, 1)); k <- !is.na(a) & !is.na(b)
        if (sum(k) < 3L || sd(a[k]) == 0 || sd(b[k]) == 0) { text(.5, .5, 'r = NA'); return(invisible()) }
        r <- cor(a[k], b[k]); rho <- cor(a[k], b[k], method = 'spearman')
        text(.5, .6, sprintf('r = %.2f', r), cex = 1.3 + abs(r))
        text(.5, .36, sprintf('rho = %.2f\nn = %d', rho, sum(k)), cex = .95, col = 'grey35')
      }
      panel_pts <- function(a, b, ...) {
        points(a, b, pch = 16, cex = .55, col = adjustcolor(ink, .45))
        k <- !is.na(a) & !is.na(b)
        if (sum(k) >= 3L && length(unique(a[k])) > 1L) lines(lowess(a[k], b[k]), col = warm, lwd = 1.5)
      }
      pairs(x, lower.panel = panel_pts, upper.panel = panel_cor, diag.panel = panel_hist,
            main = paste0('Scatterplot matrix (pairwise complete; no group labels)', suffix))
    }, finally = dev.off())
    scatter_done <- TRUE
  }

  png(file.path(dir, 'correlation_heatmap.png'), width = max(900, 300 + 110 * p), height = max(800, 300 + 100 * p), res = 120)
  tryCatch({
    r <- cors$pearson
    par(mar = c(max(6, max(nchar(vars)) * .55), max(6, max(nchar(vars)) * .55), 4.5, 2))
    pal <- colorRampPalette(c('#2B6CB0', '#F7F7F7', '#C53030'))(201)
    image(seq_len(p), seq_len(p), t(r[p:1, , drop = FALSE]), zlim = c(-1, 1), col = pal, axes = FALSE, xlab = '', ylab = '',
          main = paste0('Pearson correlation (pairwise complete)', if (is.null(title)) '' else paste0('\n', title)),
          cex.main = .95)
    axis(1, seq_len(p), vars, las = 2, cex.axis = .85); axis(2, seq_len(p), rev(vars), las = 1, cex.axis = .85)
    for (i in seq_len(p)) for (j in seq_len(p)) {
      text(j, p + 1 - i, if (is.na(r[i, j])) 'NA' else sprintf('%.2f', r[i, j]), cex = if (p > 8) .7 else 1)
    }
    box()
  }, finally = dev.off())
  scatter_done
}

# Writes all EDA outputs into `dir` (which must exist). Returns a compact summary list.
stage2_eda <- function(x, dir, title = NULL) {
  if (!is.data.frame(x) || ncol(x) < 2L || !all(vapply(x, is.numeric, logical(1)))) stop('EDA needs >= 2 numeric columns.', call. = FALSE)
  if (any(vapply(x, function(v) any(is.infinite(v)), logical(1)))) stop('EDA cannot run with Inf values; review them first.', call. = FALSE)
  desc <- stage2_descriptives(x)
  cors <- stage2_correlations(x)
  coll <- stage2_collinearity(x, desc)
  write.csv(desc, file.path(dir, 'descriptive_stats.csv'), row.names = FALSE)
  write.csv(cors$pearson, file.path(dir, 'correlation_pearson.csv'))
  write.csv(cors$spearman, file.path(dir, 'correlation_spearman.csv'))
  write.csv(cors$pair_n, file.path(dir, 'correlation_pairwise_n.csv'))
  write.csv(cors$pairs, file.path(dir, 'correlation_pairs.csv'), row.names = FALSE)
  jsonlite::write_json(coll, file.path(dir, 'collinearity.json'), auto_unbox = TRUE, pretty = TRUE, digits = NA, null = 'null', na = 'null')
  scatter <- stage2_eda_plots(x, cors, dir, title)
  files <- c(setdiff(EDA_FILES, 'eda_summary.json'), if (scatter) 'scatter_matrix.png', 'eda_summary.json')
  s <- list(title = title, n_rows = nrow(x), n_variables = ncol(x), variables = names(x),
            n_complete_rows = sum(complete.cases(x)),
            univariate_basis = 'observed values per variable (available-case)',
            correlation_basis = 'pairwise complete observations',
            collinearity_basis = coll$basis,
            scatter_matrix = if (scatter) 'scatter_matrix.png' else paste('skipped: more than', EDA_SCATTER_MAX_VARS, 'variables'),
            outlier_flags = as.list(setNames(as.integer(desc$n_iqr_outliers), desc$variable)),
            collinearity_flags = coll$flags, external_label_used = FALSE, data_modified = FALSE,
            files = I(files))
  jsonlite::write_json(s, file.path(dir, 'eda_summary.json'), auto_unbox = TRUE, pretty = TRUE, digits = NA, null = 'null', na = 'null')
  invisible(s)
}

stage2_eda_required_files <- function(n_vars) c(EDA_FILES, if (n_vars <= EDA_SCATTER_MAX_VARS) 'scatter_matrix.png')
