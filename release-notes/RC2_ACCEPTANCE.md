# 驗收候選版 rc2：修改與 Windows 驗收報告

> **歷史紀錄。** 目前的候選版是 rc3，見 `RC3_ACCEPTANCE.md`。rc2 的 ZIP 和原始檔保存在開發專案的 `release/cowork-r43/previous/rc2/`。

- 日期：2026-11-11（Asia/Taipei）
- 狀態：**Cowork 驗收候選版，尚未完成 Cowork R1–R9 實測，不宣稱完整支援 Cowork。**
- 測試環境：Windows 11、R 4.5.1

## 版本與雜湊

| 版本 | 檔案 | SHA-256 |
|---|---|---|
| rc1（修訂前基準） | `release/cowork-r43/previous/rc1/multivariate-gmm.zip` | `6222f5ebe5cc9ff741ebaa1936628de4fe842f9247236fcf3104cf7f2496134a` |
| **rc2** | `release/cowork-r43/multivariate-gmm.zip`（與 `release/github-classroom/multivariate-gmm.zip` 相同） | `13f0983e8cf8ed1f337bb6dfb1abb6ef2981e756ff2d114d637058d1745f4f29` |
| rc2 SKILL.md | — | 見 `release_manifest.csv` |

**rc1 → rc2：** 37 個檔案中**只有 `SKILL.md` 改變**，所有 R 腳本、references、example_data 都與 rc1 逐位元相同。

## SKILL.md 修改清單

**依已核准的 `SKILL-interaction-v1.diff` 套用（新增 41 行、修改 1 行）：**
1. 新增「Guiding the user (one decision at a time)」一節：
   - 以初學者為對象，用使用者的語言回答；
   - 一次只問目前需要決定的事；
   - 每個選項用一到兩句話說明；
   - 選項是編號的文字清單，不稱為按鈕；
   - 使用者說「你決定」時，再說明一次利弊並請使用者自己選，不代為決定；
   - 決定後用一句話複述並記錄；
   - 預設不顯示指令；
   - 用白話說明各種結果狀態；
   - 12 個決策點的依序對照表，其中包含 Stage 6 是否比較其他 G；
   - 7 個名詞的一句話解釋。
2. 核准點對照表的 `init` 改為 `new-run (or init)`。

**依本次核准要求補充（新增 1 行、修改 2 行）：**
3. 匯入設定（標題列、分隔符、編碼、缺失值標記）可以一起確認；**不同的統計決策依對照表的順序一個一個問**。
4. 新增 Exit 0（SUCCESS）與 WARNING 的白話說明，並明訂「WARNING 不會讓任何核准被跳過或縮短」。
5. 對照表第 7 列（Stage 3）明訂順序：標準化 → 各列是否獨立 → G 範圍，最後再核准整份設定。

**沒有改的部分：** 原有核准點、Outcome Contract、Decision Tree、門檻、R 程式。

## 其他同步更新

| 檔案 | 修改 |
|---|---|
| `INSTALL_zh-TW.md` | 說明選項是編號清單、不一定是按鈕；匯入格式一起確認；Stage 3 依序詢問；「你決定」時 Claude 會再問；WARNING 與 BLOCKED 的意思；Stage 6 可能詢問是否比較其他 G |
| `WALKTHROUGH_zh-TW.md` | 狀態說明改為 rc2；Stage 3 改成依序回答並複述；WARNING 不會省略核准 |
| `README.md` | 版本狀態改為 rc2，並列出 rc1 基準雜湊；說明互動方式 |
| `presentation/gmm-skill-presentation.qmd`、`.html`（公開副本） | 「完整版教材」3 個連結改為 `../docs/full-tutorial/gmm-skill-tutorial.html`；差異見 `presentation_link_fix.csv`。`tutorial/` 原檔沒有修改 |
| `presentation/README.md` | 註明公開副本與已核准版的唯一差異 |

### 報告版連結的修正方式

採最小修正：只在公開副本中做文字替換，沒有重新產生 HTML，因為重新產生需要未公開的正式結果。

| 檔案 | 替換內容 | 處數 | 改變的行 |
|---|---|---|---|
| QMD | `](gmm-skill-tutorial.html)` → `](../docs/full-tutorial/gmm-skill-tutorial.html)` | 3 | 第 57、135、356 行 |
| HTML | `href="gmm-skill-tutorial.html"` → `href="../docs/full-tutorial/gmm-skill-tutorial.html"` | 3 | 第 5434、5549、6088 行 |

其餘內容與已核准版逐字相同。替換前後的雜湊值記錄在 `presentation_link_fix.csv`。

## 驗收結果

| # | 檢查 | 結果 |
|---|---|---|
| 1 | SKILL.md 語法與 frontmatter | **通過**，見下方細節 |
| 2 | ZIP 結構與必要檔案 | **通過**，見下方細節 |
| 3 | ZIP 與 Skill 原始檔的 SHA-256 一致性 | **通過**，見下方細節 |
| 4 | Windows 既有回歸測試 | **863 / 863 通過**，17 / 17 個測試檔 PASS，12.7 分鐘。測試資料夾只在執行時暫時放入，事後已移除，ZIP 雜湊不變 |
| 5 | GitHub 所有 Markdown、HTML 的本機連結 | **通過**：31 個檔案、19 個本機連結，失效 0 個 |
| 6 | QMD 與 HTML 內容一致性 | **通過**，見下方細節 |
| 7 | 受保護檔案 | **通過**，見下方細節 |

**1. SKILL.md 語法與 frontmatter**
- frontmatter 只有 `name` 和 `description` 兩個欄位；
- `name` 與資料夾名稱相同；
- description 272 字元，符合 1024 的上限，但仍超過說明中心提到的 200 字元。rc1 用同一段 description 上傳成功過；
- SKILL.md 共 468 行，低於建議的 500 行；
- 程式碼區塊和表格欄數都正確；
- 引用的 28 個檔案都存在；
- 11 項必要條文都在；
- 核准點對照表只有 `init` 那一列改變。

**2. ZIP 結構與必要檔案**
- 37 個項目，最上層只有一個 `multivariate-gmm/` 資料夾；
- 必要檔案齊全；
- 沒有 tests、results、RDS、狀態檔或隱藏檔。

**3. SHA-256 一致性**
- ZIP、`github-classroom/skill/` 和 `cowork-r43/` 三處的 37 個檔案逐位元相同；
- `release_manifest.csv` 與 ZIP 一致；
- manifest 記錄的原始 Skill 雜湊與目前的原始 Skill 相同。

**6. QMD 與 HTML 內容一致性**
- 報告版：25 個標題、2 個提示框標題、3 個連結，在 QMD 和 HTML 中都一致；
- 完整版：73 個標題、13 個提示框標題一致，而且與 `tutorial/` 逐位元相同；
- 報告版公開副本與原檔只差替換連結的那 3 行。

**7. 受保護檔案**
- `tutorial/` 的 5 個已核准檔案雜湊值不變；
- 第一版 `release/cowork` 的 ZIP 不變；
- rc1 ZIP 已保留作為修訂前基準；
- 原始 Skill、`results`、`data`、`config` 最後寫入時間都早於本輪。

完整的檢查輸出在 `rc2_checks.txt`，共 44 項全部通過；公開檔案清單在 `PUBLIC_FILES.csv`。

## 尚未完成

- **Cowork R1–R9 實測。**
- **新的互動規則在實際對話中的效果。** 例如是否真的一次只問一件事、遇到「你決定」時是否會再問，都只能在 Cowork 對話中驗證。
- **授權條款。** 尚未決定，見 `LICENSE_NOTES.md`。
