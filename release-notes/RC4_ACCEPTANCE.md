# 驗收候選版 rc4：修改與 Windows 驗收報告

- 日期：2026-11-12（Asia/Taipei）
- 狀態：**Cowork 待驗收候選版。** rc4 尚未在 Cowork 實測，不宣稱完整支援 Cowork；GitHub 發佈資料夾已同步，但尚未公開。
- 測試環境：Windows 11、R 4.5.1、jsonlite 2.0.0
- 依據：`release/proposals/rc4-zh-TW/` 01–09（2026-11-12 核准）

## 1. 版本與雜湊

| 版本 | ZIP | SHA-256 |
|---|---|---|
| rc3（修訂前基準） | `release/cowork-r43/previous/rc3/multivariate-gmm.zip` | `999fae4104515b3d067b0dc6d014b6ae26a73187ebe1993a3b2a57a2480b3f15` |
| **rc4** | `release/cowork-r43/multivariate-gmm.zip`（與 `release/github-classroom/multivariate-gmm.zip` 相同） | `7cb13d8b32ce3bb5491fd8d8e904e809a5ef47627e22b243bfba9ca8f27558ac` |

rc3 已完整保存在 `release/cowork-r43/previous/rc3/`，共 45 個檔案：ZIP、manifest、diff、驗收報告、展開的原始碼和檢查紀錄。

## 2. rc3 → rc4 逐檔差異

38 個檔案中，**33 個逐位元相同**，包括所有統計程式和 references。詳見 `RC4_CHANGES_FROM_RC3.csv` 和 `.diff`。

| 檔案 | 狀態 | 修改內容 |
|---|---|---|
| `scripts/report_text.R` | 新增 | 繁體中文報告文字、122 個代碼的中文說明、附錄 A 共 41 項的中文說明、15 張圖的中文圖說，以及中文報告產生函式 `rp_zh_report()` |
| `scripts/report_final.R` | 修改（+9 −5 行） | 新增 `lang` 參數與 `--lang en\|zh-TW`（預設 en）；載入 `report_text.R`；英文報告組好之後，若選中文，再用同一批已讀取的資料產生中文；manifest 新增 `report_language`；程式檢查碼清單加入 `report_text.R` |
| `scripts/workflow.R` | 修改（+6 −4 行） | `report` 指令新增 `--lang`；狀態檔只新增 `stages$report_lang` |
| `scripts/check_env.R` | 修改（+3 行） | 新增一行 Locale 的 INFO 資訊；原有 4 項檢查和結束碼不變 |
| `SKILL.md` | 修改（+6 −4 行） | description 改為繁體中文（142 字元）；決策點第 12 步在產生報告前詢問語言（預設建議繁體中文）；說明 `--lang` 和報告語言與分析分離 |

**沒有修改：** `data_import.R`、`data_stage2.R`、`eda_stage2.R`、`feasibility_stage3.R`、`em_stage4.R`、`select_stage4.R`、`confirm_stage4.R`、`interpret_stage5.R`、`validate_stage6.R`、`sensitivity_workflow.R`、`knn_audit.R`、`warnings_registry.R`、`hash_utils.R`，以及全部 references。

### 與核准計畫的一處差異（請你確認）

09 原本計畫把英文報告文字從 `report_final.R` 逐字搬進 `report_text.R` 的文字表。實作時改成：**英文報告的程式完全不動**，中文報告由 `report_text.R` 的 `rp_zh_report()` 依同一批已讀取的資料另外產生。

這樣做的理由：
- 英文輸出最不可能改變。T-2 證實它和 rc3 除了產生時間與程式檢查碼外逐字相同。
- 中英文共用資料讀取和 `md_table()`，所以數字一定一致。

代價是 `report_text.R` 只管理中文文字，英文文字仍留在 `report_final.R`。

### 呈現上的兩處小調整

- 第 4 節的檢查項目中文名，以及附錄 A 的中文說明，改用**另外一張表或一段文字**呈現，沒有加在原表中。這樣英文版的每張表都能在中文版中原樣找到，方便逐表比對數值。
- 中文版的 NA、NaN 照原值顯示為 `NA`、`NaN`；英文版維持原本的 `-`。

## 3. Windows 驗收結果（T-1 至 T-11）

| # | 測試 | 結果 |
|---|---|---|
| T-1 | 完整回歸測試 | **863 / 863 通過**，17 / 17 個測試檔 PASS，11.4 分鐘。tests 只在執行時暫時放入，事後已移除 |
| T-2 | 英文報告與 rc3 比較 | **全部通過**：情境 A、B、C、D、E、F、H 的英文 `final_report.md`，除了產生時間和程式檢查碼清單外逐字相同；manifest 只多 `report_language = "en"` |
| T-3 | 中英數值一致 | **通過**：每個情境中，英文的每張表都原樣出現在中文版；英文內文的每個數字都出現在中文版；兩份 manifest 的 `sources`（MD5 和 SHA-256）相同；`pending_heuristics.csv`、`warnings_registry_snapshot.csv` 和所有圖檔逐位元相同 |
| T-4 | 報告語言不影響分析 | **通過**（C、D、E、F）：產生中文報告、英文報告，以及用 rc3 再產生一份之後，分析資料夾中的所有檔案雜湊不變；狀態檔的 spec、模型清單、active model 和模型 ID 不變，只新增 `report_lang = ["en", "zh-TW"]` |
| T-5 | 中文報告內容 | **通過**：有效的 UTF-8；沒有未填入的模板；章節與英文版相同（12 節加附錄 A、B；只做診斷時省略第 4–10 節，和英文版一致）；英文的每個代碼都出現在中文版；自動診斷的英文原句全部原樣引用；每張圖都有中文圖說 |
| T-6 | 條件情境 | **通過**，見第 4 節 |
| T-7 | 成分描述沿用 Stage 5 | **通過**：邊界值 d = ±0.5、±0.4999、±0.5001 的分類與 Stage 5 逐項相同；變數名稱含 `.`、`_`、`-`、數字都正確；格式不符時改顯示英文原句；可以逐字組回的特殊名稱照常解析 |
| T-8 | 代碼字典 | **通過**：程式會輸出的 135 個代碼（含狀態字和 S3-01 到 S3-15）都有中文說明 |
| T-9 | 附錄 A | **通過**：41 項登錄表維持原值；中文說明 41 項；`sd_ratio_scale` 標示「⚠ 規格與實作不一致」，並寫出實際規則（> 100） |
| T-10 | SHA-256 與 check_env | **58 / 58 通過**（W2、W4、W5、W6）；新的 `report_text.R` 可以獨立載入；check_env 輸出 Locale 資訊列 |
| T-11 | 發佈一致性 | 見第 5 節 |

T-2 到 T-9 合計 **99 項，全部通過**。完整紀錄在 `rc4_test_log.txt`。

## 4. 測試情境（T-6）

| 情境 | 內容 | 重點結果 |
|---|---|---|
| A | 已核准的 Penguins 分析（manifest，唯讀） | 中英文都產生 15 張圖；ARI／NMI 屬情況 A（正常計算） |
| B | 已核准的 Automobile 分析：KNN、沒有標籤、分析者註記、模型來源、設定檔限制、mclust、參考 Stage 4 | 中英文都通過；外部驗證寫「未執行」 |
| C | Penguins 的 rc4 workflow，含與 G = 4 比較 | 情況 A；沒有出現「不適合直接解讀」 |
| D | 只做診斷 | 第 4–10 節省略；明寫「不做任何分群結論」 |
| E | 單一常態模擬資料，兩類標籤 | BIC 選 G = 1；中文寫「沒有證據支持分成多個混合成分」「沒有分群結果可以解釋」；ARI／NMI 屬情況 B（依公式為 0，**不代表完全不一致**） |
| F | 單一常態模擬資料，只有一類的標籤 | 情況 C：「兩邊都只有一類，程式依特別規則給 ARI = NMI = 1……不能當作驗證成功」 |
| G | 標籤全部缺失 | 既有的 Stage 6 會以 `EXECUTION_ERROR` 停止（rc3 原本行為，已記入 S-3）。情況 D（n_used = 0）由單元測試驗證：原值 NaN 照實顯示，並說明不可解讀為一致 |
| H | 強制不收斂：select_stage4 搭配 `--max-iter 3` | 40 個起始點未收斂；中文寫明「沒有得到有效解，不用於選模」；第 5、6 節之後寫「未執行」 |
| 單元 S | 兩邊都是每列各自一類 | 情況 S：說明特別分支的數值不能當作一般一致性證據（S-2） |

## 5. 發佈一致性（T-11）

ZIP 共 38 個檔案，最上層只有 `multivariate-gmm/`；ZIP、`cowork-r43/multivariate-gmm/` 和 `github-classroom/skill/` 逐檔相同（SHA-256），也與 manifest 一致。

**受保護的檔案都沒有改動：**
- 原始 Skill；
- `results/`、`data/`、`config/`、`tutorial/`；
- `release/cowork/`；
- 封存的 `previous/rc1`、`rc2`、`rc3`。

## 6. 示範報告

`demo-penguins-rc4/zh-TW/` 和 `demo-penguins-rc4/en/` 是由已核准的 Penguins manifest 產生的完整報告，含圖檔、manifest 和 CSV。這兩份報告內含本機專案路徑，只供審核，**不公開**。

## 7. 尚未解決

- 規格差異 S-1 到 S-6（`SPEC_ISSUES.md`），rc4 都沒有處理。
- Cowork 實測項目：
  - 中文 description 能否上傳，以及中文、英文請求都能觸發 Skill；
  - 產生報告前的語言詢問；
  - R 4.3.3 的 UTF-8 locale；
  - 中文報告是否正常顯示；
  - rc3 尚未完成的 R1–R9。
- 中文圖表（rc5）。
