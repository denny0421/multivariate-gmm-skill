# Windows 回歸測試報告：multivariate-gmm Cowork R 4.3 相容版

- 測試日期：2026-11-10 至 11（Asia/Taipei）
- 環境：Windows 11、R 4.5.1、jsonlite 2.0.0
- 受測版本：`release/cowork-r43/multivariate-gmm/`（ZIP SHA-256 `6222f5eb…134a`）
- **限制：** 本報告只涵蓋 Windows 開發環境，**不代表已通過 Cowork R 4.3.3 測試**。R 4.3.3 和 Linux `sha256sum` 的實際行為，要在 Cowork 用 R1–R9 另行驗證。

## 結果總覽

| 測試 | 內容 | 結果 |
|---|---|---|
| W1 | 原本的完整回歸測試（17 個檔案），對發佈版執行 | **863 / 863 通過**，17 / 17 檔案 PASS，13.1 分鐘。包含 Penguins、Automobile 已核准結果的唯讀比對 |
| W2 | 五個 SHA-256 呼叫位置；所有輸出中名為 sha / sha256 的欄位 | **通過**。`tools::sha256sum()` 只在 `hash_utils.R` 中呼叫；已無 MD5、NULL、NA 替代路徑；Penguins 完整流程中 32 個 JSON 檔、52 個 sha 值全部是 64 位十六進位字元；報告 manifest 36 個來源檔，sha256 為 NA 的有 0 個 |
| W3 | Penguins Stage 1–6 加報告，發佈版與已核准 Skill 在同一路徑依序執行 | **通過**（詳見下節） |
| W4 | 已知答案與特殊檔名 | **通過**：空檔案 `e3b0c442…`、"abc" `ba7816bf…`、penguins.csv `f204db2c…`；檔名含空白、引號、`&`、`;`、`$`、反引號、中文、開頭為 `-`，兩種實作都和 `tools::sha256sum` 相同；任意順序下檔名與雜湊仍正確對應 |
| W5 | 模擬故障 | **通過**：見下方 W5 一節。所有故障都報錯，不改用 MD5 |
| W6 | 每支 CLI 都能載入共用函式 | **通過**：16 支 R 檔用 `source()` 載入的結束碼與已核准版相同；五支需要的 CLI 都載入了 `skill_sha256`；`check_env.R` 正常時結束碼 0（`ENV_OK`），SHA-256 損壞時結束碼 1（`ENV_SHA256_UNAVAILABLE`） |

W2、W4、W5、W6 合計 57 項，全部通過。

## W3：Penguins 完整流程比對

**每一步的結束碼和 Outcome Code 完全相同：**

| 步驟 | 結束碼 | Code |
|---|---|---|
| preview | 0 | PREVIEW_READ_ONLY |
| import | 0 | IMPORTED |
| new-run | 0 | CREATED |
| stage2 | 2 | MISSING_DATA_CHOICE |
| complete-case | 0 | PROCESSED_AWAITING_GMM_APPROVAL |
| stage3 第一次檢查 | 2 | STAGE3_DECISIONS_REQUIRED |
| stage3 核准 | 0 | APPROVED_FOR_FIT |
| stage4 | 0 | PASS |
| stage5 | 0 | DONE |
| stage6 | 0 | DONE |
| report | 0 | DONE |
| status | 0 | complete |

**輸出檔案：** 兩邊都是 134 個，檔名完全相同。

**完全相同（逐位元組）：** 103 個檔案，其中：
- CSV 50 / 51（包含所有參數、posterior、比較表與 EDA 表）
- PNG 42 / 42
- TXT 2 / 2

**數值與正式 Penguins 結果的差異（全部是完全相同，不是容忍誤差內）：**

| 項目 | 差異 |
|---|---|
| 各 G 的 log-likelihood、BIC、AIC | 0 |
| 選擇的 G | 3，與正式結果相同 |
| 成分平均 | 0 |
| ARI | 0.9603061495，與正式值相同 |
| NMI | 0.9349403885，與正式值相同 |

**其餘 31 個檔案不完全相同。** 遮蔽時間、run ID、import ID、approval ID，以及 32 或 64 位的雜湊值和 model ID 之後，只剩 `final_report.md` 多了一行 `hash_utils.R` 的 checksum。差異的原因如下：

- **spec_hash：** spec_hash 是規格 JSON 的 MD5，而規格裡的輸入路徑包含 run 資料夾名稱，資料夾名稱含時間戳記。兩邊儲存的 spec_hash 都能用**已核准版**的 `hash_object()` 重算出相同的值，表示計算方式沒有改變。
- **`selected_model.rds`：** 除了 spec_hash 欄位之外，其餘內容完全相同（G、par、loglik、features、scale、settings、row_ids）。
- **model ID：** model ID 取自 RDS 檔的 SHA-256，而 RDS 裡含 spec_hash，所以 model ID 也跟著不同。
- **報告中的 checksum：** 三支被修改的腳本 checksum 不同，另外多列了 `hash_utils.R`。

## W5：故障模擬

用代替 `sha256sum` 的測試程式，模擬以下故障：

| 模擬情況 | 結果 |
|---|---|
| 非零結束碼 | 報錯 |
| 輸出亂碼 | 報錯 |
| 只有 63 位 | 報錯 |
| 輸出 MD5（32 位） | 報錯 |
| 兩行輸出 | 報錯 |
| 空輸出 | 報錯 |
| 指令不存在 | 報錯 |
| PATH 中沒有 sha256sum 和 shasum | 報錯，訊息寫明「Hashes are never replaced by MD5」 |
| 傳入資料夾、空路徑、NA 路徑 | 報錯 |
| 未知的 backend 設定 | 報錯 |

**透過真實 CLI 的測試：**
- 雜湊指令失敗時，`data_import.R import` 結束碼 1，不寫出任何檔案。
- 雜湊指令輸出 MD5 時，同樣結束碼 1，不寫出檔案。
- 雜湊指令故障時，`workflow.R new-run` 結束碼 1，不建立 run。
- 透過系統指令路徑正常匯入時，記錄的 SHA-256 與 `tools::sha256sum` 相同。

**缺失或被改動的檔案：** 原本的處理方式保持不變。
- standardized 檔不存在：結束碼 1，訊息為「Standardized file not found」，與已核准版相同。
- standardized 檔被改動：結束碼 4（REFUSED）。
- 檔案恢復後即可繼續。

## 測試中發現並已修正的問題

`hash_utils.R` 第一版在呼叫系統指令時，於 Windows 上重複加了引號，因為 Windows 的 `system2()` 會自行替程式路徑加引號。修正後改為只在 Linux 和 macOS 加引號，W1 和 W2–W6 都在修正後的最終程式碼上重跑。
