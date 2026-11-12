# Stage 4A–4B — EM for a full-covariance Gaussian mixture: verified formulas

Implementation: `scripts/em_stage4.R`. The notation is used consistently in code, outputs and reports.

## Notation

| Symbol | Meaning | Code |
|---|---|---|
| n, p, G | rows, features, components | `n`, `p`, `G` |
| x_j ∈ ℝᵖ | row j of the analysis matrix (approved z-scores for Penguins) | `X[j, ]` |
| π_i | mixing proportion, π_i > 0, Σ_i π_i = 1 | `pi[i]` |
| μ_i ∈ ℝᵖ | component mean | `mu[i, ]` |
| Σ_i | p×p symmetric positive-definite covariance (component-specific, unconstrained, mclust "VVV") | `Sigma[[i]]` |
| τ_ji | posterior responsibility P(component i \| x_j) | `tau[j, i]` |
| N_i = Σ_j τ_ji | effective membership | `Nk[i]` |
| θ = {π, μ, Σ} | all parameters; free count k_G = (G−1) + Gp + Gp(p+1)/2 | — |

## Model and observed-data log-likelihood

f(x_j; θ) = Σ_{i=1..G} π_i φ_p(x_j; μ_i, Σ_i)

log φ_p(x; μ, Σ) = −(p/2) log(2π) − (1/2) log|Σ| − (1/2)(x−μ)ᵀ Σ⁻¹ (x−μ)

ℓ(θ) = Σ_j log Σ_i π_i φ_p(x_j; μ_i, Σ_i)

**Stable evaluation.** Let Σ_i = RᵢᵀRᵢ (Cholesky, Rᵢ upper triangular). Then:
- log|Σ_i| = 2 Σ log diag(Rᵢ);
- the quadratic form is ‖Rᵢ⁻ᵀ(x−μ_i)‖², computed by a triangular solve (no explicit inverse).

Define a_ji = log π_i + log φ_p(x_j; μ_i, Σ_i) and m_j = max_i a_ji.

log-sum-exp: ℓ_j = m_j + log Σ_i exp(a_ji − m_j), and ℓ = Σ_j ℓ_j.

## E-step (at current θ⁽ᵗ⁾)

τ_ji = π_i φ_p(x_j; μ_i, Σ_i) / Σ_h π_h φ_p(x_j; μ_h, Σ_h) = exp(a_ji − ℓ_j)

By construction 0 ≤ τ_ji ≤ 1 and Σ_i τ_ji = 1. The same pass returns ℓ(θ⁽ᵗ⁾), so the log-likelihood recorded at iteration t belongs to the parameters *before* the M-step of iteration t+1.

## M-step (maximises Q(θ | θ⁽ᵗ⁾) = Σ_j Σ_i τ_ji [log π_i + log φ_p(x_j; μ_i, Σ_i)])

- N_i = Σ_j τ_ji
- π_i = N_i / n (Lagrange multiplier for Σ π_i = 1)
- μ_i = (1/N_i) Σ_j τ_ji x_j
- Σ_i = (1/N_i) Σ_j τ_ji (x_j − μ_i)(x_j − μ_i)ᵀ, using the **updated** μ_i and divisor **N_i** (MLE; not N_i − 1). In code: `crossprod(sqrt(tau_i) * (X − μ_i)) / N_i`, then symmetrised as (Σ + Σᵀ)/2 to remove rounding asymmetry.

**Check of the derivation.** ∂Q/∂μ_i = Σ_j τ_ji Σ_i⁻¹(x_j − μ_i) = 0 gives the weighted mean. ∂Q/∂Σ_i⁻¹ = (1/2) Σ_j τ_ji [Σ_i − (x_j−μ_i)(x_j−μ_i)ᵀ] = 0 gives the weighted scatter / N_i. These agree with Stage 4 spec §4B. (Hair et al. Chapter 4, pp. 226–227, only names EM as the estimation method for model-based clustering and gives no M-step formulas, so it is not a source for this check.) **Result: formulas verified; no discrepancy.**

**G = 1.** The MLE is closed-form: μ = x̄ and Σ = (1/n) Σ_j (x_j − x̄)(x_j − x̄)ᵀ, with τ ≡ 1. It is computed directly as one "converged" step.

## Iteration, convergence and monotonicity

1. Initialise θ⁽⁰⁾ from a start (below); E-step → ℓ⁽⁰⁾.
2. For t = 1, 2, …: M-step from τ⁽ᵗ⁻¹⁾ → θ⁽ᵗ⁾; validity checks; E-step → τ⁽ᵗ⁾, ℓ⁽ᵗ⁾.
3. **Converged** when |ℓ⁽ᵗ⁾ − ℓ⁽ᵗ⁻¹⁾| / (1 + |ℓ⁽ᵗ⁻¹⁾|) < tol (default 1e-6), checked after a full M+E step.
4. Reaching `max_iter` (default 1000) without meeting the criterion → `NOT_CONVERGED`. This is never treated as converged.
5. EM guarantees ℓ⁽ᵗ⁾ ≥ ℓ⁽ᵗ⁻¹⁾ in exact arithmetic. A decrease with relative size ≤ 1e-10 is floating-point noise: it is counted and reported (`n_ll_decreases`). A larger decrease is **flagged** (`LL_DECREASE`). If it exceeds 1e-6 relative, the run is `NUMERIC_ERROR`, because it signals a numerical problem.

### What the stopping rule does not establish

The rule looks at one step. On a plateau the step is small even though ℓ rises substantially later, so "converged" only means that the rule was met. On UCI Automobile G = 5, starts 5 and 15 stopped at ℓ = −366.622 under tol = 1e-6 and reached −359.771 when continued. A true local optimum had almost the same relative change, Aitken estimate and parameter step at its stop, so these tail quantities cannot separate the two cases.

`scripts/confirm_stage4.R` (diagnostic, optional) therefore replays every valid start and continues it with the **same** EM map under a stricter tolerance. These cases are separate:

| Case | Operational definition | Status |
|---|---|---|
| Possible premature stop | same start, strict run valid, gain = ℓ_strict − ℓ_original ≥ 0.1 | `POSSIBLE_PREMATURE_STOP` |
| No material change | same start, strict run valid, gain < 0.1; below the strict best → behaves like a separate optimum at this strictness (not proven a local maximum) | `NO_MATERIAL_CHANGE` |
| Initialisation failure | EM never started | `INVALID_START` → `NOT_ELIGIBLE` |
| Covariance degeneracy | a guard failed during EM; a gain here is not evidence, because the mixture likelihood is unbounded | `DEGENERATE` → `NOT_ELIGIBLE`, or `STRICT_DEGENERATE` when continued |

At fixed G, ΔBIC = ΔAIC = −2Δℓ. The thresholds are project heuristics, not statistical tests (`pending-heuristics.md`). The module does not change EM, and its output cannot replace a model.

## Validity checks (after every M-step)

| Condition | Status | Reason |
|---|---|---|
| Any non-finite π, μ, Σ or ℓ | `NUMERIC_ERROR` | invalid update |
| N_i < `min_effective_n` (default p + 1) or π_i ≤ 0 | `DEGENERATE` (empty/tiny component) | fewer than p+1 effective rows cannot support a full covariance |
| Cholesky of Σ_i fails | `DEGENERATE` (covariance not positive definite) | the density is undefined |
| λ_max(Σ_i)/λ_min(Σ_i) > `max_cov_condition` (default 1e10) | `DEGENERATE` (covariance collapse) | the likelihood is unbounded near a singular Σ, so a large ℓ is not evidence of fit |

**No covariance regularisation** is added (`regularization = "none"` in the output). A failed start is recorded with its reason and never counted as a valid optimum. The thresholds `min_effective_n` and `max_cov_condition` are project choices, not yet calibrated by simulation (review R07).

## Initialisation (multi-start)

- Default: 20 starts, base seed 421; start s uses seed 421 + s − 1.
- `kmeans` (default): one k-means run (random centres, Lloyd/Hartigan–Wong, ≤ 100 iterations) gives a hard partition. Its M-step gives θ⁽⁰⁾. k-means uses Euclidean distance, so the z-score scale makes this initialisation scale-free.
- `random`: a uniformly random hard partition, then the M-step.
- A start whose initial partition has a component with fewer than p+1 rows, or a non-PD initial covariance, is `INVALID_START`.

**Per-G result.** The start with the highest ℓ among `CONVERGED_VALID` runs is kept. Other optima within 1e-6 relative of the best count as "reaching the best"; distinct local optima are reported, and global maximality is not claimed.

## Comparison with mclust (tests only)

`mclust::Mclust(X, G, modelNames = "VVV")` maximises the same likelihood but starts from model-based hierarchical clustering, and by default adds no prior. Compare:
- the log-likelihood (ours ≥ mclust − tolerance, since multi-start can reach an equal or better optimum);
- the parameters, after **label alignment** (the permutation of components minimising the mean distance between μ's), within tolerance.

mclust's BIC sign convention is irrelevant here, because Stage 4A–4B computes no BIC/AIC.
