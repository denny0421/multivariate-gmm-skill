# Stage 5 checklist — v1.2

| ID | Test | On failure | Evidence |
|---|---|---|---|
| I01 | Selected converged valid Stage 4 model available | STOP | model ID, fit status |
| I02 | Fit and transformation metadata match approved data | PAUSE | row IDs, file hash, transform parameters |
| I03 | Posterior probabilities finite, 0..1, row sum=1 | STOP | numeric checks |
| I04 | MAP labels match maximum posteriors, ties deterministic | PAUSE/STOP | classification export |
| I05 | Mixing weights and empirical MAP shares separately shown | PAUSE | component table |
| I06 | Component means/covariances finite and valid | STOP | parameter table |
| I07 | Original-unit inverse transforms correct and labeled | PAUSE | transformation audit |
| I08 | Uncertainty and posterior entropy properly defined | PAUSE | uncertainty summary |
| I09 | G=1 produces no claims of meaningful partition | WARNING | report text |
| I10 | Group labels are descriptive, tentative and evidence-based | WARNING/PAUSE | interpretation text |
| I11 | PCA/scatter visual is labeled as projection if applicable | WARNING | plot captions |
| I12 | Outputs include caveats about overlap and interpretation | PAUSE | report |
