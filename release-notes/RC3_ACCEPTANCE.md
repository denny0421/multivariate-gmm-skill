# 驗收候選版 rc3：修改與 Windows 驗收報告

- 日期：2026-11-11（Asia/Taipei）
- 狀態：**Cowork 驗收候選版。** rc3 本身尚未在 Cowork 做 R1–R9 正式驗收，不宣稱完整支援 Cowork。
- 測試環境：Windows 11、R 4.5.1

## 版本與雜湊

| 版本 | ZIP | SHA-256 |
|---|---|---|
| rc1 | `release/cowork-r43/previous/rc1/multivariate-gmm.zip` | `6222f5ebe5cc9ff741ebaa1936628de4fe842f9247236fcf3104cf7f2496134a` |
| rc2（修訂前基準） | `release/cowork-r43/previous/rc2/multivariate-gmm.zip` | `13f0983e8cf8ed1f337bb6dfb1abb6ef2981e756ff2d114d637058d1745f4f29` |
| **rc3** | `release/cowork-r43/multivariate-gmm.zip`，與 `release/github-classroom/multivariate-gmm.zip` 相同 | `999fae4104515b3d067b0dc6d014b6ae26a73187ebe1993a3b2a57a2480b3f15` |

rc2 的 ZIP、manifest、diff、驗收報告、檢查紀錄與展開的原始檔，都完整保存在 `release/cowork-r43/previous/rc2/`。

## rc2 → rc3 逐檔差異

**37 個檔案中，36 個逐位元相同，只修改 `scripts/hash_utils.R`**（見 `RC3_CHANGES_FROM_RC2.csv` 和 `.diff`）。

| 行 | rc2 | rc3 |
|---|---|---|
| 7 | `HASH_UTILS_VERSION <- '1.0.0'` | `HASH_UTILS_VERSION <- '1.0.1'`，加註版本說明 |
| 38 | `prog <- if (.Platform$OS.type == 'windows') cmd[1] else shQuote(cmd[1])` | `prog <- cmd[1]`，並把原本錯誤的註解更正為正確說明 |

**改動原因：** `system2()` 在 Windows（R 4.5.1）和 Cowork 的 Unix（R 4.3.3）上，都會自行替程式路徑加引號。rc2 在 Unix 上又加了一次，結果變成雙重引號，外部的 `sha256sum` 就無法執行。

**版本號：** `HASH_UTILS_VERSION` 只在 `hash_utils.R` 中定義。它不會寫入任何輸出紀錄，也不參與任何雜湊，所以更新為 1.0.1 不會造成相容性問題。報告中列出的腳本 checksum 本來就會因為檔案內容改變而不同。

**沒有改的部分：** SKILL.md、其他所有 R 程式、references、Decision Tree、門檻、核准流程。

## Windows 驗收結果

| # | 項目 | 結果 |
|---|---|---|
| 1 | 完整回歸測試 | **863 / 863 通過**，17 / 17 個測試檔 PASS，10.9 分鐘。tests 只在執行時暫時放入，事後已移除，ZIP 雜湊不變 |
| 2 | SHA-256 已知答案與特殊檔名 | **通過**。空檔案和 "abc" 的已知答案、penguins.csv，以及檔名含空白、引號、`&`、`;`、`$`、反引號、中文、開頭為 `-` 的檔案，兩種實作的結果都與 `tools::sha256sum` 相同，順序打亂後對應也正確 |
| 3 | Windows 的 `system2()` 路徑 | **通過**。以測試用的 `sha256sum` 替代程式走系統指令路徑，已知答案、特殊檔名、真實 CLI 匯入都正確；8 種故障情境全部報錯停止，不會改用 MD5 |
| 4 | R 4.5.1 的 `tools::sha256sum()` 路徑 | **不受影響**。預設仍走 `tools`，self-test 通過，W2–W6 共 57 / 57 通過 |
| 5 | rc2 與 rc3 的統計輸出 | **沒有差異**，見下方細節 |
| 6 | 受保護檔案 | **全部不變**，見下方細節 |
| — | ZIP、展開的 Skill、GitHub 原始檔 | **逐檔一致**，見下方細節 |

**第 5 項細節：** 用 Penguins 跑完 Stage 1–6 加報告，rc2 和 rc3 在同一路徑依序執行。
- 12 個步驟的結束碼和 Outcome Code 都相同；
- 51 個 CSV 中有 50 個、42 個 PNG 全部逐位元相同；
- log-likelihood、BIC、AIC、成分平均的差異都是 0；ARI 和 NMI 完全相同；
- 遮蔽時間、ID 和雜湊值之後，沒有任何檔案不同。

剩下的差異只有三種：每次執行都不同的 spec_hash（因為含 run 資料夾路徑）、由它衍生的 model ID，以及報告中 `hash_utils.R` 的 checksum。

**第 6 項細節：**
- 原始 Skill、`results`、`data`、`config` 最後寫入時間都早於本輪；
- `tutorial/` 的 5 個已核准檔案雜湊不變；
- `release/cowork` 的 ZIP 不變；
- rc1 和 rc2 的 ZIP 都已保留。

**ZIP 一致性細節：** 37 個檔案，ZIP、`release/cowork-r43/`、`github-classroom/skill/` 三處的 SHA-256 全部相同；manifest 一致；SKILL.md 與 rc2 相同，核准點對照表也相同。

**其他檢查：** GitHub 資料夾的本機連結 19 個，失效 0 個；QMD 和 HTML 一致性檢查通過；`rc3_checks.txt` 共 45 項全部通過。

## Cowork 尚未完成的驗收項目

用 rc3 ZIP 重新上傳後，需要在 Cowork 完成：

- **R1：** Linux `sha256sum` 已知答案。已用暫存副本單項測試過，需用 rc3 正式重做。
- **R2：** 匯入時記錄的 SHA-256 和 MD5，與 Windows 的紀錄相同。
- **R3：** 各個核准點、完整性檢查，以及檔案被改動時是否 REFUSED。
- **R4：** Penguins Stage 1–6 完整流程，數值與正式結果比對（容忍誤差 1e-6）。
- **R5：** KNN 的暫停與稽核紀錄。
- **R6：** 模型清單與警告登錄。
- **R7：** 報告 manifest 沒有 NA，所有 PNG 都有內容。
- **R8：** 環境紀錄，以及新任務是否需要重裝 R。
- **R9：** 受保護檔案不變。
- **互動規則：** rc2 加入的規則（一次只問一件事、遇到「你決定」會再問、不稱為按鈕）在實際對話中的表現。
