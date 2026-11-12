# Stage 4 execution checklist — v1.1

Status values: `PASS`, `WARNING`, `PAUSE`, `STOP`, or (for a single run) `FAILED`.

| ID | Check | Action when failed | Evidence |
|---|---|---|---|
| M01 | Approved Stage 1–3 spec and immutable data | PAUSE | spec hash; approval record |
| M02 | Candidate G set valid and documented | PAUSE/STOP | candidate G and n,p |
| M03 | Full-covariance parameter count checked | WARNING/STOP | k_G and feasibility note |
| M04 | Initialization valid; random state recorded | retry approved start or FAILED | start ID, seed, initial weights/covariances |
| M05 | E-step responsibilities finite and row sums ~1 | FAILED | row-sum and finite diagnostics |
| M06 | M-step weights >0, means finite, covariance positive definite | FAILED | N_i, eigenvalues, conditioning |
| M07 | Observed log-likelihood finite; monotonicity checked | WARNING/FAILED | iteration history and tolerance |
| M08 | Explicit convergence criterion met before max_iter | NOT_CONVERGED; exclude | iteration count, delta loglik |
| M09 | All attempted starts recorded; best valid kept | WARNING if partial failures | run status table |
| M10 | BIC/AIC calculated with correct k and sign | STOP model ranking if inconsistent | selection table and formula |
| M11 | Candidate models comparable: same data/features/preprocessing | STOP cross-model ranking | analysis-data hash and transform record |
| M12 | G=1 allowed and interpreted correctly | WARNING on forced segmentation | candidate list, selected G |
| M13 | No valid models leads to diagnostic-only report | STOP | failures and suggested revisions |
| M14 | Hand-off files and warnings complete | PAUSE final interpretation if absent | artifact manifest |

A numerical failure does not authorize automatic row deletion, covariance changes, regularization, or new G search limits. Such changes require a revised analysis spec and approval.
