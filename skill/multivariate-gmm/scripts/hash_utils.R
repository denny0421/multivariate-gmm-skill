# SHA-256 of files for the multivariate-gmm Skill (Cowork release, R >= 4.1).
# R >= 4.5 uses tools::sha256sum(). Older R uses the system "sha256sum" (Linux coreutils) or, failing that,
# "shasum -a 256" (macOS). The file is passed on standard input, so its name never reaches the command line.
# There is no MD5 fallback and no silent NA: a file that does not exist gives NA, exactly as tools::sha256sum()
# does (so a check against a recorded hash fails); every other problem stops with an error.
# MD5 fields and spec_hash elsewhere in the Skill are unchanged.
HASH_UTILS_VERSION <- '1.0.1' # 1.0.1: system command no longer quoted twice on Unix (rc3)
SKILL_SHA256_RE <- '^[0-9a-f]{64}$'

skill_sha256_fail <- function(...) stop(paste0('SHA-256: ', ...), call. = FALSE)

# The implementation in use. Two options exist for testing only and are never set in normal use:
#   options(multivariate_gmm.sha256_backend = 'tools' or 'system') forces one implementation;
#   options(multivariate_gmm.sha256_command = c(<program>, <leading arguments>)) replaces the system command.
skill_sha256_backend <- function() {
  forced <- getOption('multivariate_gmm.sha256_backend')
  has_tools <- exists('sha256sum', envir = asNamespace('tools'), inherits = FALSE)
  if (!is.null(forced)) {
    if (identical(forced, 'tools')) {
      if (!has_tools) skill_sha256_fail('tools::sha256sum() is not available in R ', as.character(getRversion()), '.')
      return(list(type = 'tools', command = NULL))
    }
    if (!identical(forced, 'system')) skill_sha256_fail('unknown backend option "', paste(forced, collapse = ' '), '".')
  } else if (has_tools) return(list(type = 'tools', command = NULL))
  cmd <- getOption('multivariate_gmm.sha256_command')
  if (is.null(cmd)) {
    p <- Sys.which('sha256sum')
    if (nzchar(p)) cmd <- unname(p) else { p <- Sys.which('shasum'); if (nzchar(p)) cmd <- c(unname(p), '-a', '256') }
  }
  if (!length(cmd) || !nzchar(cmd[1]))
    skill_sha256_fail('no SHA-256 implementation found. R ', as.character(getRversion()), ' has no tools::sha256sum() (added in R 4.5.0), ',
                      'and neither "sha256sum" nor "shasum" is on the PATH. Hashes are never replaced by MD5.')
  list(type = 'system', command = as.character(cmd))
}

# One file through the system command. Its output must be exactly one line "<64 hex>  -".
skill_sha256_system <- function(f, cmd) {
  prog <- cmd[1] # system2() quotes the program itself (seen on Windows R 4.5.1 and Cowork R 4.3.3); quoting it here doubles the quotes
  out <- suppressWarnings(tryCatch(system2(prog, shQuote(cmd[-1]), stdin = f, stdout = TRUE, stderr = TRUE),
                                   error = function(e) structure(conditionMessage(e), status = -1L)))
  st <- attr(out, 'status')
  if (!is.null(st) && !identical(as.integer(st), 0L))
    skill_sha256_fail('"', paste(cmd, collapse = ' '), '" failed (exit status ', st, ') for ', f, ': ', paste(out, collapse = ' '))
  out <- out[nzchar(trimws(out))]
  if (length(out) != 1L) skill_sha256_fail('unexpected output from "', cmd[1], '" for ', f, ': ', if (length(out)) paste(out, collapse = ' | ') else '(none)')
  m <- regmatches(out, regexec('^\\\\?([0-9A-Fa-f]{64})[ \t]+\\*?-[ \t]*$', out))[[1]]
  if (length(m) != 2L) skill_sha256_fail('malformed output from "', cmd[1], '" for ', f, ': ', out)
  tolower(m[2])
}

# SHA-256 of each file, named by the paths as given (like tools::sha256sum()).
skill_sha256 <- function(files) {
  files <- as.character(files)
  if (!length(files)) return(setNames(character(), character()))
  if (anyNA(files) || any(!nzchar(files))) skill_sha256_fail('a file path is missing or empty.')
  b <- skill_sha256_backend()
  out <- rep(NA_character_, length(files))
  present <- file.exists(files)
  if (any(dir.exists(files))) skill_sha256_fail('not a regular file: ', files[dir.exists(files)][1])
  if (any(present)) {
    fp <- files[present]
    unreadable <- fp[file.access(fp, 4L) != 0L]
    if (length(unreadable)) skill_sha256_fail('cannot read ', unreadable[1])
    out[present] <- if (identical(b$type, 'tools')) unname(tools::sha256sum(fp)) else vapply(fp, skill_sha256_system, '', cmd = b$command, USE.NAMES = FALSE)
    bad <- present & (is.na(out) | !grepl(SKILL_SHA256_RE, out))
    if (any(bad)) skill_sha256_fail('invalid digest for ', files[bad][1], ': ', out[bad][1])
  }
  names(out) <- files
  out
}

# Known answers (FIPS 180-2): the empty input and "abc".
SKILL_SHA256_KNOWN <- c(empty = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                        abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
skill_sha256_selftest <- function() {
  d <- tempfile('sha256-selftest-'); dir.create(d); on.exit(unlink(d, recursive = TRUE))
  f <- file.path(d, c('empty', 'abc')); writeBin(raw(0), f[1]); writeBin(charToRaw('abc'), f[2])
  h <- unname(skill_sha256(f))
  if (!identical(h, unname(SKILL_SHA256_KNOWN))) skill_sha256_fail('known-answer test failed: ', paste(h, collapse = ', '))
  invisible(skill_sha256_backend()$type)
}
