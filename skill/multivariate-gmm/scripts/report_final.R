#!/usr/bin/env Rscript
# Final integrated report for the multivariate-gmm Skill (Stages 1-6). Generic.
# Every number in the report is read from existing stage outputs (JSON/CSV); nothing is re-estimated.
# Missing stages (diagnostics-only workflow, no Stage 6, no external labels) are reported as "not performed".
suppressPackageStartupMessages(library(jsonlite))

rp_script_path <- function() {
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(normalizePath(of, winslash = '/')) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE))
  NA_character_
}
RP_SCRIPT_DIR <- dirname(rp_script_path())
if (!exists('stage6_validate', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'validate_stage6.R'), local = TRUE)
if (!exists('STAGE3_THRESHOLDS', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'feasibility_stage3.R'), local = TRUE)
if (!exists('S4_THRESHOLDS', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'select_stage4.R'), local = TRUE)
if (!exists('CONFIRM_THRESHOLDS', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'confirm_stage4.R'), local = TRUE)
if (!exists('wr_report_section', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'warnings_registry.R'), local = TRUE)
if (!exists('skill_sha256', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'hash_utils.R'), local = TRUE) # Cowork release: SHA-256 on R >= 4.1
if (!exists('rp_zh_report', inherits = TRUE)) source(file.path(RP_SCRIPT_DIR, 'report_text.R'), local = TRUE, encoding = 'UTF-8') # rc4: zh-TW report text
RP_VERSION <- '0.1.0'
RP_SCRIPTS <- c('data_stage2.R', 'eda_stage2.R', 'feasibility_stage3.R', 'em_stage4.R', 'select_stage4.R', 'confirm_stage4.R', 'warnings_registry.R', 'interpret_stage5.R', 'validate_stage6.R', 'report_final.R', 'workflow.R', 'hash_utils.R', 'report_text.R')

# ---------------------------------------------------------------- heuristic threshold registry (single source for the pending list)
gmm_heuristics_registry <- function() {
  row <- function(stage, name, value, type, use, where) data.frame(stage = stage, name = name, value = paste(format(value), collapse = ', '), type = type, use = use, location = where, stringsAsFactors = FALSE)
  out <- list(
    row('2 (EDA)', 'abs_r flag', EDA_FLAG_ABS_R, 'heuristic', '|Pearson r| above this is flagged', 'eda_stage2.R EDA_FLAG_ABS_R'),
    row('2 (EDA)', 'condition index flag', EDA_FLAG_CONDITION, 'heuristic', 'sqrt(lambda_max/lambda_min) of correlation flagged', 'eda_stage2.R EDA_FLAG_CONDITION'),
    row('2 (EDA)', 'VIF flag', EDA_FLAG_VIF, 'heuristic', 'VIF above this is flagged', 'eda_stage2.R EDA_FLAG_VIF'),
    row('2 (EDA)', 'IQR outlier rule', '1.5 x IQR', 'heuristic (Tukey)', 'boxplot whiskers / outlier counts', 'eda_stage2.R'),
    row('2 (EDA)', '|z| outlier count', 3, 'heuristic', 'count of |z| > 3', 'eda_stage2.R'),
    row('2 (EDA)', 'scatter-matrix size limit', EDA_SCATTER_MAX_VARS, 'display choice', 'scatterplot matrix skipped above this many variables', 'eda_stage2.R'),
    row('2 (missing)', 'KNN k suggestion', 5, 'heuristic', 'suggested default k; user chooses', 'SKILL.md / data_stage2.R'))
  for (k in names(STAGE3_THRESHOLDS)) { t <- STAGE3_THRESHOLDS[[k]]; if (!grepl('^exact', t$type)) out[[length(out) + 1]] <- row('3', k, t$value, t$type, t$use, 'feasibility_stage3.R STAGE3_THRESHOLDS') }
  out[[length(out) + 1]] <- row('4A-4B', 'min_effective_n', 'p + 1', 'heuristic', 'EM guard: smaller effective component size -> DEGENERATE', 'em_stage4.R')
  out[[length(out) + 1]] <- row('4A-4B', 'max_cov_condition', EM_DEFAULTS$max_cov_condition, 'heuristic', 'EM guard: covariance condition number -> DEGENERATE', 'em_stage4.R EM_DEFAULTS')
  out[[length(out) + 1]] <- row('4A-4B', 'log-lik decrease bands', sprintf('noise <= %g; flagged > %g; error > %g', EM_DEFAULTS$ll_noise_rel, EM_DEFAULTS$ll_noise_rel, EM_DEFAULTS$ll_error_rel), 'heuristic', 'monotonicity checks', 'em_stage4.R EM_DEFAULTS')
  out[[length(out) + 1]] <- row('4A-4B', 'initialisation', EM_DEFAULTS$init, 'project choice', 'k-means hard partition per start', 'em_stage4.R')
  for (k in names(S4_THRESHOLDS)) { t <- S4_THRESHOLDS[[k]]; if (!grepl('^exact|^reference', t$type) && !k %in% c('min_effective_n', 'max_cov_condition')) out[[length(out) + 1]] <- row('4C-4D', k, t$value, t$type, t$use, 'select_stage4.R S4_THRESHOLDS') }
  for (k in names(S5_THRESHOLDS)) { t <- S5_THRESHOLDS[[k]]; if (identical(t$type, 'heuristic')) out[[length(out) + 1]] <- row('5', k, t$value, t$type, t$use, 'interpret_stage5.R S5_THRESHOLDS') }
  for (k in names(S6_THRESHOLDS)) { t <- S6_THRESHOLDS[[k]]; if (t$type %in% c('heuristic', 'descriptive', 'convention')) out[[length(out) + 1]] <- row('6', k, if (is.null(t$value)) t$formula else t$value, t$type, if (is.null(t$use)) '' else t$use, 'validate_stage6.R S6_THRESHOLDS') }
  out[[length(out) + 1]] <- row('6', 'NMI normalisation', 'arithmetic: 2I/(H(U)+H(V))', 'choice', 'other normalisations exist (geometric, max)', 'validate_stage6.R s6_nmi')
  for (k in names(CONFIRM_THRESHOLDS)) { t <- CONFIRM_THRESHOLDS[[k]]; out[[length(out) + 1]] <- row('4 (confirmation)', k, t$value, 'heuristic', t$use, 'confirm_stage4.R CONFIRM_THRESHOLDS') }
  out[[length(out) + 1]] <- row('4A-4B', 'random-soft responsibilities', 'Dirichlet(1,...,1)', 'heuristic', 'distribution of the initial responsibilities for init = random-soft; not adjustable by the user', 'em_stage4.R em_init_soft_tau')
  r <- do.call(rbind, out); r$status <- 'PENDING REVIEW (project choice; not a textbook rule)'; r
}

# ---------------------------------------------------------------- helpers
rp_json <- function(dir, f) { p <- file.path(dir, f); if (!is.null(dir) && file.exists(p)) jsonlite::fromJSON(p, simplifyVector = TRUE) else NULL }
rp_csv <- function(dir, f) { p <- file.path(dir, f); if (!is.null(dir) && file.exists(p)) read.csv(p, check.names = FALSE, stringsAsFactors = FALSE) else NULL }
rp_fmt <- function(x, d = 4) { if (is.numeric(x)) ifelse(is.na(x), '-', ifelse(abs(x) >= 1e5 | (abs(x) < 1e-3 & x != 0), formatC(x, format = 'g', digits = 3), formatC(x, format = 'f', digits = d, drop0trailing = FALSE))) else ifelse(is.na(x), '-', as.character(x)) }
md_table <- function(df, d = 4) {
  if (is.null(df) || !nrow(df)) return('*(no rows)*')
  fmt_col <- function(col) {
    if (is.numeric(col) && all(is.na(col) | (abs(col) < 1e15 & col == round(col)))) return(ifelse(is.na(col), '-', formatC(col, format = 'd', big.mark = '')))
    rp_fmt(col, d)
  }
  cells <- vapply(df, function(col) gsub('|', '\\|', fmt_col(col), fixed = TRUE), character(nrow(df)))
  if (is.null(dim(cells))) cells <- matrix(cells, nrow = 1)
  c(paste0('| ', paste(names(df), collapse = ' | '), ' |'), paste0('|', strrep('---|', ncol(df))), apply(cells, 1, function(r) paste0('| ', paste(r, collapse = ' | '), ' |')))
}

# Stops if Stage 4, 5 and 6 outputs do not come from one model and one Stage 3 spec (applies to workflow and hand-written manifests).
rp_check_lineage <- function(dirs) {
  same <- function(a, b) !is.null(a) && !is.null(b) && identical(path_key(a), path_key(b))
  rc5 <- rp_json(dirs$stage5, 'run_config.json'); rc6 <- rp_json(dirs$stage6, 'run_config.json')
  if (!is.null(dirs$stage4) && !is.null(rc5) && !same(rc5$stage4_dir, dirs$stage4)) fail('Model source mismatch: Stage 5 was produced from ', rc5$stage4_dir, ', not from the report\'s Stage 4 model ', dirs$stage4, '.')
  if (!is.null(dirs$stage4) && !is.null(rc6) && !same(rc6$stage4_dir, dirs$stage4)) fail('Model source mismatch: Stage 6 was produced from ', rc6$stage4_dir, ', not from the report\'s Stage 4 model ', dirs$stage4, '.')
  if (!is.null(dirs$stage5) && !is.null(rc6) && !same(rc6$stage5_dir, dirs$stage5)) fail('Model source mismatch: Stage 6 was produced from Stage 5 ', rc6$stage5_dir, ', not from the report\'s Stage 5 ', dirs$stage5, '.')
  if (!is.null(dirs$stage5) && is.null(dirs$stage4)) fail('Model source mismatch: the report has Stage 5 results but no Stage 4 model.')
  if (!is.null(dirs$stage6) && is.null(dirs$stage5)) fail('Model source mismatch: the report has Stage 6 results but no Stage 5 results.')
  spec <- rp_json(dirs$stage3_approved, 'stage3_spec.json')$spec_hash
  for (k in c('stage4', 'stage5', 'stage6')) {
    v <- switch(k, stage4 = rp_json(dirs$stage4, 'selected_model.json')$spec$spec_hash, stage5 = rp_json(dirs$stage5, 'stage5_summary.json')$spec$spec_hash, stage6 = rp_json(dirs$stage6, 'stage6_summary.json')$spec$spec_hash)
    if (!is.null(spec) && !is.null(v) && !identical(spec, v)) fail('Spec mismatch: ', k, ' output was produced under spec ', v, ', but the report uses Stage 3 spec ', spec, '.')
  }
  invisible(TRUE)
}

# ---------------------------------------------------------------- main
final_report <- function(manifest, output, lang = 'en') {
  if (!identical(length(lang), 1L) || !lang %in% RP_LANGS) fail('Report language must be one of: ', paste(RP_LANGS, collapse = ', '), '.')
  m <- manifest
  output_path <- resolve_path(output)
  if (path_within(output_path, STAGE2_SKILL_ROOT)) fail('Output path is inside the Skill directory.')
  if (dir.exists(output_path) && length(list.files(output_path, all.files = TRUE, no.. = TRUE))) fail('Output directory already contains files; choose a new directory (existing results are never overwritten): ', output_path)
  dirs <- lapply(m[c('stage2_diagnostics', 'stage2_processing', 'stage3_approved', 'stage4', 'stage4_reference', 'stage5', 'stage6', 'stage6_replay')], function(x) if (is.null(x) || !nzchar(x)) NULL else resolve_path(x))
  names(dirs) <- c('stage2_diagnostics', 'stage2_processing', 'stage3_approved', 'stage4', 'stage4_reference', 'stage5', 'stage6', 'stage6_replay')
  if (is.null(dirs$stage2_diagnostics) || !dir.exists(dirs$stage2_diagnostics)) fail('The Stage 2 diagnostics directory is required.')
  for (k in names(dirs)) if (!is.null(dirs[[k]]) && !dir.exists(dirs[[k]])) fail('Directory for ', k, ' not found: ', dirs[[k]])
  rp_check_lineage(dirs)
  used <- character(); figs <- list()
  J <- function(k, f) { v <- rp_json(dirs[[k]], f); if (!is.null(v)) used <<- c(used, file.path(dirs[[k]], f)); v }
  C <- function(k, f) { v <- rp_csv(dirs[[k]], f); if (!is.null(v)) used <<- c(used, file.path(dirs[[k]], f)); v }
  F <- function(k, f, caption) { p <- if (is.null(dirs[[k]])) NULL else file.path(dirs[[k]], f); if (!is.null(p) && file.exists(p)) { nm <- paste0(k, '__', gsub('/', '_', f)); figs[[nm]] <<- p; sprintf('![%s](figures/%s)', caption, nm) } else character() }

  d2 <- J('stage2_diagnostics', 'summary.json'); rc2 <- J('stage2_diagnostics', 'run_config.json'); lg2 <- J('stage2_diagnostics', 'preprocessing_log.json')
  pr <- dirs$stage2_processing; lgp <- if (!is.null(pr)) J('stage2_processing', 'preprocessing_log.json') else NULL; sp2 <- if (!is.null(pr)) J('stage2_processing', 'summary.json') else NULL
  s3 <- J('stage3_approved', 'stage3_spec.json'); s3c <- C('stage3_approved', 'stage3_checks.csv'); s3cand <- C('stage3_approved', 'candidate_feasibility.csv')
  mc <- C('stage4', 'model_comparison.csv'); sel <- J('stage4', 'selected_model.json'); rc4 <- J('stage4', 'run_config.json'); cs4 <- J('stage4', 'convergence_summary.json')
  s5 <- J('stage5', 'stage5_summary.json'); cs5 <- C('stage5', 'component_summary.csv'); cm5 <- C('stage5', 'component_means.csv'); sd5 <- C('stage5', 'component_sd_original.csv')
  us5 <- J('stage5', 'uncertainty_summary.json'); amb5 <- C('stage5', 'ambiguous_observations.csv')
  s6 <- J('stage6', 'stage6_summary.json'); st6 <- C('stage6', 'stability_summary.csv'); ms6 <- C('stage6', 'model_sensitivity.csv'); ex6 <- J('stage6', 'external_validation.json')
  # outputs written before the 'available' flag existed carry results under 'selected'
  if (!is.null(ex6) && is.null(ex6$available)) ex6$available <- !is.null(ex6$selected)
  w6 <- C('stage6', 'stability_within_optimum_ari.csv'); b6 <- C('stage6', 'stability_between_optima_ari.csv'); cl6 <- C('stage6', 'component_label_table.csv'); str6 <- C('stage6', 'strata_check.csv')

  feats <- if (!is.null(d2)) d2$variables else m$columns
  done <- c(`Stage 2 diagnostics` = TRUE, `Stage 2 processing` = !is.null(pr), `Stage 3 approved spec` = !is.null(s3), `Stage 4 fit + selection` = !is.null(mc),
            `Stage 5 interpretation` = !is.null(s5), `Stage 6 validation` = !is.null(s6))
  dx_only <- identical(m$stage2_decision, 'diagnostics-only')
  L <- c(sprintf('# %s', if (is.null(m$title)) 'Gaussian mixture model analysis report' else m$title), '',
         sprintf('- Generated: %s UTC by `report_final.R` v%s.', format(Sys.time(), '%Y-%m-%d %H:%M', tz = 'UTC'), RP_VERSION),
         sprintf('- Stages included: %s.', paste(sprintf('%s (%s)', names(done), ifelse(done, 'yes', 'no')), collapse = '; ')),
         '- **Every number below is read from the stage output files listed in `report_manifest.json`. No model was re-estimated for this report.**',
         if (dx_only) '- The workflow ended after missing-data diagnostics at the user\'s choice ("Diagnostics only"); no model was fitted.' else NULL,
         if (!is.null(m$model_source_note)) paste('- Model source:', m$model_source_note) else NULL,
         if (!is.null(m$active_model_id)) sprintf('- Active approved model: `%s` (G = %s, log-lik %.4f, BIC %.3f; Stage 4 output `%s`).', m$active_model_id, m$active_model$G, m$active_model$loglik, m$active_model$BIC, m$active_model$dir) else NULL)

  # 1 objectives
  L <- c(L, '', '## 1. Research objectives', '',
         sprintf('- Objective (user-stated): %s', if (is.null(m$objective_text)) 'not recorded' else m$objective_text),
         sprintf('- Analysis type: %s (unsupervised Gaussian mixture, full covariance).', if (!is.null(s3$objective)) s3$objective else if (!is.null(m$objective)) m$objective else 'not recorded'),
         sprintf('- Modelling features (%d): %s.', length(feats), paste(feats, collapse = ', ')),
         sprintf('- External label: %s.', if (is.null(m$label)) 'none' else sprintf('`%s`, reserved for post-hoc validation (Stage 6); never used for estimation or model selection', m$label)))

  # 2 data and EDA
  e2 <- if (!is.null(pr)) 'stage2_processing' else 'stage2_diagnostics'
  ds <- C('stage2_diagnostics', 'eda/descriptive_stats.csv'); cp <- C('stage2_diagnostics', 'eda/correlation_pairs.csv'); co <- J('stage2_diagnostics', 'eda/collinearity.json')
  L <- c(L, '', '## 2. Data description and EDA', '',
         sprintf('- Input: `%s` (MD5 `%s`), %d rows; %d selected variables.', if (!is.null(lg2)) lg2$input$path else m$input, if (!is.null(lg2)) lg2$input$md5 else '-',
                 if (!is.null(d2)) d2$n_observations else NA, length(feats)),
         if (!is.null(m$data_source)) sprintf('- Data source record: `%s` (reproduced in Appendix B).', m$data_source) else NULL,
         '', '**Descriptive statistics (observed values per variable; Stage 2 EDA)**', '',
         md_table(if (is.null(ds)) NULL else ds[, intersect(c('variable', 'n_observed', 'n_missing', 'mean', 'sd', 'min', 'median', 'max', 'skewness', 'excess_kurtosis', 'n_iqr_outliers', 'n_abs_z_gt3'), names(ds))]),
         '', '**Pairwise correlations (pairwise complete)**', '', md_table(if (is.null(cp)) NULL else cp[, intersect(c('var1', 'var2', 'n_pairwise', 'pearson_r', 'ci95_low', 'ci95_high', 'spearman_rho'), names(cp))]),
         '', if (!is.null(co)) sprintf('- Collinearity (complete rows, n = %d): condition index %s; full rank: %s; flags: %s.', co$n_complete_rows, rp_fmt(co$condition_number, 2),
                                         co$full_rank, if (length(co$flags)) paste(co$flags, collapse = '; ') else 'none') else NULL,
         '', F('stage2_diagnostics', 'eda/distributions.png', 'Distributions'), '', F('stage2_diagnostics', 'eda/boxplots.png', 'Boxplots'), '',
         F('stage2_diagnostics', 'eda/scatter_matrix.png', 'Scatterplot matrix'), '', F('stage2_diagnostics', 'eda/correlation_heatmap.png', 'Correlation heatmap'))

  # 3 missing data
  vm <- C('stage2_diagnostics', 'variable_missing.csv'); ps <- C('stage2_diagnostics', 'pattern_summary.csv')
  L <- c(L, '', '## 3. Missing-data diagnostics and handling', '',
         sprintf('- Missing cells: %d of %d (rate %s); NA %d, NaN %d, Inf %d. Complete rows: %d; incomplete: %d; rows with all selected variables missing: %d%s.',
                 d2$missing_cells, d2$n_observations * d2$n_variables, rp_fmt(d2$overall_missing_rate, 4), d2$na_cells, d2$nan_cells, d2$infinite_cells, d2$complete_cases,
                 d2$incomplete_cases, d2$all_missing_row_count, if (length(d2$all_missing_source_rows)) paste0(' (source rows ', paste(d2$all_missing_source_rows, collapse = ', '), ')') else ''),
         '- The missingness mechanism (MCAR/MAR/MNAR) cannot be identified from these counts.', '', md_table(vm), '', md_table(ps), '',
         F('stage2_diagnostics', 'missingness_map.png', 'Missingness map'),
         '', sprintf('**Handling decision:** %s', switch(if (is.null(m$stage2_decision)) 'unknown' else m$stage2_decision,
           'not-needed' = 'no missing values; no handling needed.', 'diagnostics-only' = 'diagnostics only (no rows removed or imputed).',
           'processed' = sprintf('`%s`, approved by the user. Rows retained %d, removed %d (source rows: %s); imputed cells %d.', lgp$method, lgp$rows_retained, lgp$rows_removed$count,
                                 if (length(lgp$rows_removed$source_row_ids)) paste(lgp$rows_removed$source_row_ids, collapse = ', ') else 'none', lgp$imputed_cells$total),
           'undecided' = 'pending user choice from the missing-data menu.', 'unknown' = 'not recorded.')),
         if (identical(m$stage2_decision, 'processed') && !is.null(lgp) && isTRUE(lgp$imputed_cells$total > 0))
           c('', sprintf('- Imputation details: method `%s`%s; imputed cells by variable: %s. This is a single imputation: the imputed values are treated as observed in later stages and imputation uncertainty is not represented.',
                         lgp$method, if (!is.null(lgp$knn)) sprintf(', k = %d, cells with fewer than k donors = %d', lgp$knn$k, lgp$knn$cells_with_fewer_than_k_donors) else '',
                         paste(sprintf('%s = %d', names(lgp$imputed_cells$by_variable), unlist(lgp$imputed_cells$by_variable)), collapse = ', '))))

  if (!dx_only) {
    # 4 assumptions
    L <- c(L, '', '## 4. Model assumptions and limitations (Stage 3)', '')
    if (is.null(s3)) L <- c(L, '- Stage 3 has not been approved; no model was fitted.') else {
      L <- c(L, sprintf('- Approved specification `%s` (approval `%s`): scale = %s; objective = %s; independent rows = %s; G candidates = %s; covariance = %s; outliers: %s.',
                        s3$spec_hash, s3$approval_id, s3$scale$method, s3$objective, s3$rows_independent, paste(s3$G_candidates, collapse = ', '), s3$covariance, s3$outlier_policy),
             if (!is.null(s3$independence_note)) paste('- Independence note:', s3$independence_note) else NULL,
             '- No global multivariate-normality test is required (only components are assumed Gaussian).', '',
             md_table(s3c[, c('id', 'check', 'status', 'evidence')]), '', '**Candidate G feasibility**', '', md_table(s3cand[, c('G', 'k_G', 'n_per_component', 'n_over_k', 'status')]))
    }
    # 5 EM
    L <- c(L, '', '## 5. GMM estimation and EM convergence (Stage 4A-4C)', '')
    if (is.null(mc)) L <- c(L, '- Not performed.') else {
      L <- c(L, sprintf('- Settings: %s starts per G (G = 1 closed form), per-start seed = %s + s - 1, init = %s, tol = %s (relative), max_iter = %s, minimum effective n = %s, maximum covariance condition = %s, regularisation = %s.',
                        rc4$n_starts, rc4$seed, rc4$init, rc4$tol, rc4$max_iter, rc4$min_effective_n, rc4$max_cov_condition, cs4$settings$regularization),
             sprintf('- Total solves: %d (%s).', sum(mc$n_starts), paste(sprintf('G=%d: %d', mc$G, mc$n_starts), collapse = ', ')), '',
             md_table(mc[, intersect(c('G', 'n_starts', 'n_valid_starts', 'n_converged_valid', 'n_not_converged', 'n_degenerate', 'n_numeric_error', 'n_invalid_start', 'n_starts_reaching_best', 'n_distinct_optima', 'min_effective_n', 'max_cov_condition', 'diagnostic_warnings'), names(mc))]),
             '', F('stage4', 'loglik_histories.png', 'Log-likelihood histories'))
      ref <- C('stage4_reference', 'model_comparison.csv')
      if (!is.null(ref)) {
        keep <- c('G', 'n_starts', 'n_valid_starts', 'n_distinct_optima', 'loglik', 'BIC', 'AIC')
        cmp <- merge(ref[, keep], mc[, keep], by = 'G', suffixes = c('_reference', '_used'))
        L <- c(L, '', '**Comparison with the reference Stage 4 run.** "used" is the run that supplies the model in this report; "reference" is an earlier approved run, kept and not replaced.', '', md_table(cmp, 3))
      }
      # 6 selection
      L <- c(L, '', '## 6. BIC/AIC model selection (Stage 4D)', '', '- BIC = -2 logLik + k_G log n; AIC = -2 logLik + 2 k_G; smaller is better; k_G = (G-1) + Gp + Gp(p+1)/2.', '',
             md_table(mc[, intersect(c('G', 'k_G', 'loglik', 'BIC', 'delta_BIC', 'BIC_evidence_vs_selected', 'AIC', 'delta_AIC', 'eligible'), names(mc))], 3), '',
             if (!is.null(sel)) paste('-', sel$messages) else NULL, '', F('stage4', 'bic_aic.png', 'BIC and AIC'))
      if (!is.null(m$mclust_comparison) && file.exists(resolve_path(m$mclust_comparison))) {
        mp <- resolve_path(m$mclust_comparison); used <- c(used, mp); mt <- read.csv(mp, check.names = FALSE, stringsAsFactors = FALSE)
        tb <- data.frame(G = mt$G, setting = mt$setting, loglik_pipeline = mt$loglik_ours, loglik_mclust = mt$loglik_mclust, BIC_pipeline = mt$BIC_ours, BIC_mclust = -mt$BIC_mclust_reported)
        bg <- vapply(split(tb, tb$setting), function(d) d$G[which.min(d$BIC_mclust)], numeric(1))
        L <- c(L, '', '**Reference: mclust VVV (validation only; not used for estimation or selection).** BIC shown as smaller-is-better. The pipeline columns come from the validation run with its stated settings, not necessarily from the run that supplies the model in this report.', '',
               md_table(tb, 3), '', sprintf('- mclust VVV lowest BIC at G = %s (%s).', bg, names(bg)))
      }
    }
    # 7 interpretation
    L <- c(L, '', '## 7. Component interpretation (Stage 5)', '')
    if (is.null(s5)) L <- c(L, '- Not performed.') else {
      cmo <- cm5[cm5$scale == 'original', c('component', feats)]
      L <- c(L, sprintf('- Selected model G = %d. Parameters back-transformed with %s. Checks: stored posterior reproduced (max diff %s); posterior invariant under back-transformation (max diff %s).',
                        s5$selected_G, s5$scale$back_transform, rp_fmt(s5$checks$posterior_reproduced$max_abs_diff), rp_fmt(s5$checks$backtransform_posterior_invariance$max_abs_diff)),
             '- Components are density components, **not** verified natural groups, and are not named.', '',
             md_table(cs5[, c('component', 'mixing_proportion', 'effective_n', 'MAP_count', 'MAP_proportion')]), '', '**Component means (original units)**', '', md_table(cmo),
             '', '**Within-component SD (original units)**', '', md_table(sd5), '')
      for (k in seq_len(nrow(s5$components))) L <- c(L, sprintf('- Component %d: %s', s5$components$component[k], paste(unlist(s5$components$description[[k]]), collapse = '; ')))
      L <- c(L, '', F('stage5', 'mean_profile_original.png', 'Mean profile, original units'), '', F('stage5', 'mean_profile_standardized.png', 'Standardised mean profile'), '',
             F('stage5', 'correlation_heatmaps.png', 'Within-component correlations'), '', F('stage5', 'pca_projection.png', 'PCA projection'),
             '', '*The PCA plot is a visualisation only; the GMM was estimated in all selected dimensions.*')
      # 8 uncertainty
      L <- c(L, '', '## 8. Classification uncertainty', '',
             sprintf('- U = 1 - max posterior. Mean U = %s, median = %s, max = %s (maximum possible %s); mean normalised entropy = %s.', rp_fmt(us5$overall$mean_U), rp_fmt(us5$overall$median_U),
                     rp_fmt(us5$overall$max_U), rp_fmt(us5$max_U_possible), rp_fmt(us5$overall$mean_entropy_normalized)),
             sprintf('- U > 0.01: %d; > 0.05: %d; > 0.10: %d; > 0.25: %d of %d. Ambiguous rows (U > %s) are listed, not removed or reclassified.', us5$overall$n_U_gt$`0.01`, us5$overall$n_U_gt$`0.05`,
                     us5$overall$n_U_gt$`0.10`, us5$overall$n_U_gt$`0.25`, us5$n, us5$threshold_ambiguous),
             '- Posterior probabilities are model-based membership probabilities, not verified classification accuracy.', '',
             md_table(if (is.null(amb5) || !nrow(amb5)) NULL else head(amb5[, intersect(c(names(amb5)[1], 'MAP_component', 'tau_MAP', 'second_component', 'tau_second', 'uncertainty'), names(amb5))], 15)),
             '', F('stage5', 'uncertainty.png', 'Posterior uncertainty'))
    }
    # 9 stability
    L <- c(L, '', '## 9. Stability and sensitivity analysis (Stage 6A-6B)', '')
    if (is.null(s6)) L <- c(L, '- Not performed.') else {
      bsel <- if (!is.null(b6) && nrow(b6)) b6[b6$G == s6$selected_G, ] else NULL
      b6show <- if (!is.null(b6) && nrow(b6) > 15) b6[b6$optimum_a == 1, ] else b6
      L <- c(L, '### 9.1 Initialization stability', '', md_table(st6[, intersect(c('G', 'n_valid', 'n_distinct_optima', 'n_near_best', 'share_near_best', 'loglik_gap_next_optimum', 'partition_mean_ari_near_best', 'partition_min_ari_near_best', 'partition_mean_ari_all_valid', 'partition_min_ari_all_valid'), names(st6))]),
             '', if (!is.null(w6)) c('**Partition ARI within each optimum (replay)**', '', md_table(w6), '') else '- Partition-level ARI between starts: not computed (no approved replay).',
             if (!is.null(b6) && nrow(b6)) c(if (nrow(b6show) < nrow(b6)) '**Partition ARI between the best optimum and each other optimum** (all pairs: `stability_between_optima_ari.csv`)' else '**Partition ARI between distinct optima**', '', md_table(b6show), '') else NULL,
             if (!is.null(bsel) && nrow(bsel)) c(sprintf('- Selected G = %d: ARI between representative partitions of distinct optima: mean %s, range %s to %s over %d pairs. ARI between the best and the next-best optimum: %s.', s6$selected_G,
                                                         rp_fmt(mean(bsel$ari_representatives), 3), rp_fmt(min(bsel$ari_representatives), 3), rp_fmt(max(bsel$ari_representatives), 3), nrow(bsel),
                                                         rp_fmt(bsel$ari_representatives[bsel$optimum_a == 1 & bsel$optimum_b == 2], 3)), '') else NULL,
             sprintf('- Bootstrap / subsampling: %s.', s6$stability$bootstrap_subsampling), '', '### 9.2 Model sensitivity (selected vs alternative)', '',
             md_table(ms6[, intersect(c('G', 'role', 'loglik', 'k_G', 'BIC', 'delta_BIC', 'AIC', 'delta_AIC', 'MAP_sizes', 'mean_uncertainty', 'n_U_gt_0.10', 'n_distinct_optima', 'ARI_vs_selected', 'NMI_vs_selected'), names(ms6))], 3),
             '', if (length(unlist(s6$sensitivity$structure))) paste('-', unlist(s6$sensitivity$structure)) else '- No alternative G was compared.', '', sprintf('- %s', s6$primary_model), '', F('stage6', 'stability_plot.png', 'Multi-start stability'), '',
             F('stage6', 'model_sensitivity_plot.png', 'Model sensitivity'))
    }
    # 10 external validation
    L <- c(L, '', '## 10. External validation (Stage 6C)', '')
    if (is.null(ex6) || !isTRUE(ex6$available)) L <- c(L, '- **Not Performed.** No external labels were available or provided; external validation was not performed.') else {
      cls <- cl6[cl6$role == 'selected (BIC)', ]
      wide <- reshape(cls[, c('component', 'label', 'count')], idvar = 'component', timevar = 'label', direction = 'wide'); names(wide) <- sub('^count\\.', '', names(wide))
      L <- c(L, sprintf('- Label `%s` aligned by `%s`; %d rows used, %d with missing label. Used only for post-hoc evaluation (unsupervised model).', ex6$label_column, ex6$alignment_key,
                        ex6$selected$n_used, ex6$selected$n_label_missing),
             sprintf('- Selected model: **ARI = %s, NMI = %s**. %s', rp_fmt(ex6$selected$ARI), rp_fmt(ex6$selected$NMI), ex6$interpretation_guide),
             if (length(ex6$alternatives)) sprintf('- Alternative G = %s: ARI = %s, NMI = %s (sensitivity only; not used for selection).', vapply(ex6$alternatives, `[[`, numeric(1), 'G'),
                                                    vapply(ex6$alternatives, function(a) rp_fmt(a$ARI), character(1)), vapply(ex6$alternatives, function(a) rp_fmt(a$NMI), character(1))) else NULL,
             sprintf('- Matched agreement after optimal one-to-one matching (descriptive, separate from ARI/NMI): %s.', rp_fmt(ex6$selected$matched_agreement$value)), '',
             '**Component x label counts (selected model)**', '', md_table(wide), '', F('stage6', 'component_label_heatmap.png', 'Component x label'))
    }
  }

  # 11 conclusions
  L <- c(L, '', '## 11. Conclusions and limitations', '')
  if (dx_only) {
    L <- c(L, '- The analysis stopped after missing-data diagnostics by user choice; no clustering conclusion is drawn.')
  } else if (!is.null(mc) && !is.null(sel)) {
    others <- mc[mc$eligible & mc$G != sel$selected_G, ]
    nb <- if (nrow(others)) others[which.min(others$delta_BIC), ] else NULL
    L <- c(L, sprintf('- BIC selected **G = %d**%s. AIC %s.', sel$selected_G,
                      if (!is.null(nb)) sprintf(' (next best G = %d, delta BIC = %s, evidence: %s)', nb$G, rp_fmt(nb$delta_BIC, 2), nb$BIC_evidence_vs_selected) else '',
                      if (isTRUE(sel$bic_aic_agree)) 'agrees' else sprintf('preferred G = %d (kept for sensitivity analysis)', sel$aic_selected_G)),
           if (isTRUE(sel$boundary_optimum)) '- The selected G is at the upper search limit; a wider search would need a new Stage 3 approval.' else NULL)
    if (!is.null(st6)) { r <- st6[st6$G == sel$selected_G, ]
      L <- c(L, sprintf('- Stability: %d of %d valid starts reached the best optimum%s.', r$n_near_best, r$n_valid,
                        if (!is.na(r$partition_mean_ari_near_best)) sprintf('; their partitions agree (mean ARI %s); over all valid starts mean ARI %s', rp_fmt(r$partition_mean_ari_near_best, 3), rp_fmt(r$partition_mean_ari_all_valid, 3)) else '')) }
    if (isTRUE(ex6$available)) L <- c(L, sprintf('- Post-hoc agreement with `%s`: ARI %s, NMI %s. Agreement does not prove that components are natural groups.', ex6$label_column, rp_fmt(ex6$selected$ARI, 3), rp_fmt(ex6$selected$NMI, 3)))
  } else L <- c(L, '- No model has been fitted yet; conclusions are limited to the data description.')
  # Limitations come only from the stage outputs, the approved spec and registry records verified against this analysis.
  rid <- wr_identity(if (!is.null(lg2)) lg2$input$md5 else NULL, s3, dirs$stage4)
  if (!is.null(m$active_model_id) && !is.null(rid$model_id) && !identical(m$active_model_id, rid$model_id)) fail('Model identity mismatch: the manifest names active model ', m$active_model_id, ', but the Stage 4 files are model ', rid$model_id, '.')
  reg_dir <- if (is.null(m$warnings_registry) || !nzchar(m$warnings_registry)) NULL else resolve_path(m$warnings_registry)
  reg <- wr_report_section(reg_dir, rid, list(d2 = d2, lgp = lgp, decision = m$stage2_decision, co = co, s3 = s3, s3c = s3c, mc = mc, sel = sel, s6 = s6, b6 = b6, str6 = str6, ex6 = ex6, dx_only = dx_only), m$additional_limitations,
                           c('Gaussian components are density components; posterior probabilities are not verified accuracy.',
                             sprintf('%d heuristic thresholds used in this pipeline are project choices pending review (Appendix A).', nrow(gmm_heuristics_registry()))))
  used <- c(used, reg$files)
  L <- c(L, '', reg$lines)

  # 12 reproducibility
  rcs <- list(`Stage 2 diagnostics` = rc2, `Stage 2 processing` = if (!is.null(pr)) J('stage2_processing', 'run_config.json'), `Stage 3` = J('stage3_approved', 'run_config.json'),
              `Stage 4` = rc4, `Stage 5` = J('stage5', 'run_config.json'), `Stage 6` = J('stage6', 'run_config.json'))
  outdirs <- list(`Stage 2 diagnostics` = dirs$stage2_diagnostics, `Stage 2 processing` = dirs$stage2_processing, `Stage 3` = dirs$stage3_approved,
                  `Stage 4` = dirs$stage4, `Stage 5` = dirs$stage5, `Stage 6` = dirs$stage6)
  rv2 <- if (!is.null(lg2)) lg2$r_version else NULL
  rtab <- do.call(rbind, lapply(names(rcs), function(k) if (is.null(rcs[[k]])) NULL else data.frame(stage = k, script_version = if (is.null(rcs[[k]]$script_version)) '-' else rcs[[k]]$script_version,
                                                                                                    output = outdirs[[k]] %||% '-',
                                                                                                    r_version = rcs[[k]]$r_version %||% (if (grepl('^Stage 2', k)) rv2 else NULL) %||% 'not recorded')))
  sc <- file.path(RP_SCRIPT_DIR, RP_SCRIPTS); sc <- sc[file.exists(sc)]
  L <- c(L, '', '## 12. Reproducibility information', '', md_table(rtab), '',
         sprintf('- Stage 3 spec hash `%s`; approval ID `%s`.', if (is.null(s3)) '-' else s3$spec_hash, if (is.null(s3)) '-' else s3$approval_id),
         sprintf('- Replay directory: %s.', if (is.null(dirs$stage6_replay)) 'none' else sprintf('`%s`', dirs$stage6_replay)),
         sprintf('- Warnings registry: %s (records cited %d; not cited %d). All items: `warnings_registry_snapshot.csv`.', if (is.null(reg_dir)) 'none' else sprintf('`%s`', reg_dir), reg$n_applied, reg$n_refused),
         if (length(m$approval_records)) c('- Approval records:', paste0('  - `', unlist(m$approval_records), '`')) else NULL,
         if (length(m$config_files)) c('- Configuration files:', paste0('  - `', unlist(m$config_files), '`')) else NULL,
         '- Skill script checksums (MD5) at report time:', paste0('  - `', basename(sc), '` ', unname(tools::md5sum(sc))),
         '- Regression tests: `Rscript .claude/skills/multivariate-gmm/tests/run_all_tests.R`.', '- All source files read for this report, with checksums: `report_manifest.json`.')

  # appendices
  hz <- gmm_heuristics_registry()
  L <- c(L, '', '## Appendix A. Heuristic thresholds pending review', '', 'These are project screening choices, not textbook rules; they keep their "pending review" status until confirmed.', '',
         md_table(hz[, c('stage', 'name', 'value', 'type', 'use', 'location')]))
  if (!is.null(m$data_source) && file.exists(resolve_path(m$data_source))) {
    used <- c(used, resolve_path(m$data_source))
    L <- c(L, '', '## Appendix B. Data source record', '', paste('>', readLines(resolve_path(m$data_source), warn = FALSE, encoding = 'UTF-8')))
  }
  L <- enc2utf8(unlist(L))
  # rc4: the English text above is unchanged; zh-TW is written from the same objects already read (nothing re-read or re-estimated).
  if (identical(lang, 'zh-TW')) L <- rp_zh_report(environment())

  writer <- function(dir) {
    if (length(figs)) { dir.create(file.path(dir, 'figures')); for (nm in names(figs)) file.copy(figs[[nm]], file.path(dir, 'figures', nm)) }
    writeLines(L, file.path(dir, 'final_report.md'), useBytes = TRUE)
    u <- unique(c(used, unlist(m$active_model_files)))
    write_json_file(list(report_version = RP_VERSION, report_language = lang, generated_utc = format(Sys.time(), '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'), active_model_id = m$active_model_id, manifest = m,
                         sources = data.frame(file = u, md5 = unname(tools::md5sum(u)), sha256 = unname(skill_sha256(u))), figures = data.frame(copy = names(figs), source = unlist(figs, use.names = FALSE)),
                         re_estimation = FALSE), file.path(dir, 'report_manifest.json'))
    write.csv(hz, file.path(dir, 'pending_heuristics.csv'), row.names = FALSE)
    write.csv(if (is.null(reg$snapshot)) data.frame(id = character()) else reg$snapshot, file.path(dir, 'warnings_registry_snapshot.csv'), row.names = FALSE)
  }
  validator <- function(dir) { if (!file.exists(file.path(dir, 'final_report.md'))) fail('Report not written.') }
  stage_and_commit(output_path, writer, validator)
  invisible(list(output_dir = output_path, n_figures = length(figs), sections = grep('^## ', L, value = TRUE)))
}
`%||%` <- function(a, b) if (is.null(a)) b else a

rp_cli <- function(argv) {
  if (length(argv) %% 2L) fail('Arguments must use --key value pairs.')
  a <- list(); for (i in seq(1L, length(argv), 2L)) a[[sub('^--', '', argv[i])]] <- argv[i + 1L]
  if (is.null(a$manifest) || is.null(a$output)) fail('Usage: report_final.R --manifest <manifest.json> --output <new dir> [--lang en|zh-TW]')
  man <- jsonlite::fromJSON(resolve_path(a$manifest), simplifyVector = TRUE)
  man$config_files <- unique(c(man$config_files, resolve_path(a$manifest)))
  final_report(man, a$output, lang = if (is.null(a$lang)) 'en' else a$lang)
}

if (sys.nframe() == 0L) {
  r <- tryCatch(rp_cli(commandArgs(trailingOnly = TRUE)), error = function(e) { cat('Error:', conditionMessage(e), '\n', file = stderr()); quit(save = 'no', status = 1L) })
  cat(paste(r$sections, collapse = '\n'), '\n'); cat('Figures copied:', r$n_figures, '\nOutput directory:', r$output_dir, '\n')
}
