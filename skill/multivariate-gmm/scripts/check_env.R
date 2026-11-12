#!/usr/bin/env Rscript
# Environment check for the multivariate-gmm Skill: R version, jsonlite, the PNG device and SHA-256.
# Reads and writes nothing outside tempdir(). Exit 0 when everything works, 1 otherwise.
# Usage: Rscript check_env.R
ce_dir <- local({
  for (f in rev(sys.frames())) { of <- f$ofile; if (is.character(of) && length(of) == 1L && file.exists(of)) return(dirname(normalizePath(of, winslash = '/'))) }
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub('^--file=', '', a[1L]), winslash = '/', mustWork = FALSE)) else '.'
})
res <- list(); ok <- TRUE; code <- 'ENV_OK'
add <- function(item, pass, detail, fail_code) {
  res[[length(res) + 1L]] <<- sprintf('%-9s %s  %s', item, if (pass) 'OK  ' else 'FAIL', detail)
  if (!pass && ok) { ok <<- FALSE; code <<- fail_code }
}
rv <- getRversion()
add('R', rv >= '4.1.0', sprintf('%s (needs >= 4.1.0) at %s', R.version.string, R.home()), 'ENV_R_TOO_OLD')
has_json <- requireNamespace('jsonlite', quietly = TRUE)
add('jsonlite', has_json, if (has_json) as.character(utils::packageVersion('jsonlite')) else 'not installed', 'ENV_JSONLITE_MISSING')
png_ok <- tryCatch({
  f <- tempfile(fileext = '.png'); grDevices::png(f, width = 200, height = 150); graphics::plot(1:10); grDevices::dev.off()
  s <- file.size(f); unlink(f); isTRUE(s > 0)
}, error = function(e) FALSE)
add('PNG', png_ok, if (png_ok) sprintf('png() works (cairo: %s)', isTRUE(capabilities('cairo'))) else 'png() could not write a file', 'ENV_PNG_FAILED')
sha <- tryCatch({ source(file.path(ce_dir, 'hash_utils.R'), local = TRUE); b <- skill_sha256_selftest(); list(ok = TRUE, msg = sprintf('known answers pass (%s)', if (identical(b, 'tools')) 'tools::sha256sum' else paste(skill_sha256_backend()$command, collapse = ' '))) },
                error = function(e) list(ok = FALSE, msg = conditionMessage(e)))
add('SHA-256', sha$ok, sha$msg, 'ENV_SHA256_UNAVAILABLE')
utf8 <- isTRUE(l10n_info()[['UTF-8']])
res[[length(res) + 1L]] <- sprintf('%-9s INFO  LC_CTYPE = %s; UTF-8 locale: %s%s', 'Locale', Sys.getlocale('LC_CTYPE'), if (utf8) 'yes' else 'no',
                                  if (utf8) '' else ' (reports are still written as UTF-8 files; if Chinese text looks wrong, run Rscript with LC_ALL=C.UTF-8)')
cat(unlist(res), sep = '\n')
cat(sprintf('Outcome: %s\nExit-Code: %d\nStage: environment\nCode: %s\nNext-Action: %s\n', if (ok) 'SUCCESS' else 'ERROR', if (ok) 0L else 1L, code,
            if (ok) 'Start with data_import.R preview.' else 'Stop and show this to the user. Do not continue the analysis and do not compute anything by other means.'))
if (!ok) quit(save = 'no', status = 1L)
