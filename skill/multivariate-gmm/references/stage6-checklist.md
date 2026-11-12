# Stage 6 checklist — v1.3

| ID | Test | On failure | Evidence |
|---|---|---|---|
| V01 | Fitted model provenance and validity confirmed | STOP | hashes / model status |
| V02 | All starts summarized, not just winning start | WARNING/PAUSE | fit-status table |
| V03 | Label switching accounted for in component comparisons | PAUSE | matching rule, ARI |
| V04 | BIC/AIC sign and comparability consistent | STOP ranking | selection table |
| V05 | Upper search boundary, near-ties and failed fits disclosed | WARNING | sensitivity report |
| V06 | Classification uncertainty separated from density fit | WARNING | uncertainty summary |
| V07 | Optional holdout uses train-only preprocessing | STOP invalid validation | split spec, holdout scores |
| V08 | Optional resampling aligns partitions where comparable | WARNING/PAUSE | split IDs, matching logic |
| V09 | External descriptors/labels excluded from initial fit | STOP invalid external claim | feature list |
| V10 | Post-hoc interpretations and selection bias caveated | WARNING | report text |
| V11 | Conclusions calibrated to actually run checks | PAUSE | validation status |
| V12 | Reproducible seed, session and source data recorded | PAUSE | artifacts manifest |

Optional validations must explicitly record `COMPLETED`, `NOT_RUN` or `FAILED`. For density-only use, cluster-specific profiling is not required.
