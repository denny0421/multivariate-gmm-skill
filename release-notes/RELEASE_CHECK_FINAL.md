# GitHub 發布前檢查（最終版，2026-11-12）

- 範圍：本資料夾就是 repo 根目錄。
- 自動檢查結果：`final_release_checks.txt`。
- 檔案清單與 SHA-256：`PUBLIC_FILES.csv`。

## 版本

- Skill：**rc4 文件修正版**。
  - ZIP SHA-256 `9437eb63dd3541d413c5197612314821576336cc2784c0d765f10ece5c1dddf2`；
  - 38 個檔案，與 `skill/` 逐檔相同；
  - 與 rc4 相比只改 4 個文字檔，R 程式逐位元相同，見 `RC4_DOC_FIX.md`。
- 狀態：**Cowork 驗收候選版（Candidate）**。
  - rc4 尚未在 Cowork 完成正式實機驗收：R1–R9、繁體中文報告、中文 description 的上傳與觸發；
  - rc3 曾在 Cowork（R 4.3.3）完成一次 Penguins Stage 1–6。

## 本次修改

1. **Hair 引用。** `references.bib`：作者順序改為 Hair, Black, Babin, Anderson；年份 2019（版權頁 © 2019，印刷年 2018）；出版者 Cengage Learning EMEA。
2. **完整教材**（`docs/full-tutorial/` 的 QMD 與 HTML）：
   - 移除作者占位文字與發布日期；
   - Hair 第 4 章的概念加上頁碼，並說明 Skill 是「參考並延伸，不完全相同」；
   - 區分一般分群的常態性討論與 GMM 的成分常態假設；
   - 「不命名」改為本專案的保守原則；
   - 第 24 章整理為四部分：程式測試與驗收、文獻核對、41 項經驗門檻、S-1 至 S-6。
3. **Skill 文件：** 修正 4 個文字檔（見 `RC4_DOC_FIX.md`），並重新打包 ZIP。
4. **公開範圍：**
   - 移除 `presentation/`。原始簡報仍在開發專案的 `tutorial/`，公開副本備份在 repo 外。
   - 新增 GitHub Pages 入口 `docs/index.html` 與 `docs/.nojekyll`。
   - README 改為三個入口。
5. **隱私：** `rc4_test_log.txt` 的本機暫存路徑已遮蔽。

## 測試

| 項目 | 結果 |
|---|---|
| Windows 完整回歸測試（R 4.5.1） | **未全部完成，不宣稱全部通過。** 以 GitHub `skill/` 的 R 程式加上原始 tests，在暫存專案根目錄執行 863 項：<br>- 16 / 17 個測試檔 PASS；<br>- 853 項 ok、0 項 not ok；<br>- `test_warnings_registry.R` 在最後的 Automobile／Penguins 已核准結果交叉比對停止（Model source mismatch）。<br>原因：已核准的 Automobile 設定記錄的是專案的絕對路徑，而測試依 Skill 所在位置推算分析根目錄，所以只能在專案自己的 `.claude/skills/` 位置完整執行；那裡是受保護的原始 Skill，本次沒有移動或覆寫。這不是程式差異：17 個 R 程式與 rc4 逐位元相同，而 rc4 在 2026-11-12 的 T-1 為 863 / 863。約 10 項交叉比對本次未執行 |
| ZIP 完整性 | 38 項、單一最上層資料夾，與 `skill/` 逐檔 SHA-256 相同 |
| 統計結果不受影響 | R 程式、example_data、pending-heuristics 與 rc4 逐位元相同；本次只改文字 |
| 完整 HTML | UTF-8、無亂碼；78 個目錄連結都有對應的錨點；`docs/index.html` 轉到完整教材 |
| 公開內容 | 無原文書 PDF；無 results/、config/、data/；無 tests/；無本機路徑、個人帳號或金鑰。HTML 中的 `AKIA…` 只是內嵌字型的 base64 資料 |

## 先前 12 項 FAIL 的原因與處理

這 12 項 FAIL 來自另一個 Session 在 23:23 的檢查，檔案已移到 repo 外 `superseded-prerelease-reports/`。當時本 Session 正在修改 Skill、ZIP 與教材（約 23:21–23:24）。

| # | 項目 | 類別 | 原因 | 處理與現況 |
|---|---|---|---|---|
| 1 | ZIP 與 skill/ 不一致 | C | 已改 skill/ 的 4 個文字檔，但 ZIP 尚未重新打包 | ZIP 已重新打包；38 檔逐一 SHA-256 相同 → PASS |
| 2 | skill/ 與 rc4 不同 | F（預期） | 依指示修正 Hair 引用 | 確認只有 4 個文字檔各改 1 行；17 個 R 程式、example_data、pending-heuristics 都與 rc4 相同 |
| 3 | references/ 與 rc3 不同 | F（預期） | 同上，其中 3 個是 references 檔 | 同上 |
| 4 | 第 24 章只有 A、B、C | F（預期） | 依指示改為四部分 A–D | 四個標題都同時出現在 QMD 與 HTML → PASS |
| 5 | 「待核對」由 6 處減為 2 處 | F（預期，已逐項確認） | 減少的 3 處都只針對 Hair（原書未提供），現已對照原書核對 | 其他文獻的 UNVERIFIED 標記維持 10 處，與原檔相同 |
| 6 | 刪除的行不只作者與日期 | F（預期） | Hair 相關文字已更新 | 逐行差異只在 Hair 引用、第 24 章與 Stage 5 命名說明 |
| 7 | 新增的行不只在第 23–24 章 | F（預期） | 第 1 章、§三種知識來源、Decision Tree 表也加了 Hair 說明 | 同上 |
| 8 | 年份統計改變 | F（預期） | Hair 年份依版權頁由 2018 改為 2019；第 24 章新增 2026-11-12 的核對紀錄 | 其他研究年份、資料年份、參考文獻年份都保留 |
| 9 | 標題「C. `r n_hz` 項…」不在 HTML | D（檢查誤判） | 標題中的行內 R 會算成「41」 | HTML 實際顯示「C. 41 項經驗門檻及其限制」→ PASS |
| 10 | README 連結 RC4_DOC_FIX.md 失效 | B（暫時性） | 先改了 README，後建立該檔 | 檔案已建立；README、INSTALL、WALKTHROUGH 的本機連結都有效 |
| 11 | local_path 隱私 | E（誤判） | 該報告中描述掃描樣式的文字被比對到，不是真的路徑 | 報告已移出 repo；現行掃描無命中 |
| 12 | user_dir 隱私 | E（誤判） | 同上 | 同上 |

**本次最終檢查中另外修正的兩條判定規則**（在 `final_release_checks.txt` 中可見）：

- **APPROVED：** 不再把程式欄位名稱 `approved_for_fit` 算成審核狀態。
- **金鑰掃描：** 會先移除 HTML 內嵌字型與圖片的 base64 資料，因為原本命中的 `AKIA…` 只是字型資料。

兩者都先人工確認是誤判，才調整規則。

## 尚未解決

- rc4 的 Cowork 正式實機驗收。
- 41 項經驗門檻全部 PENDING REVIEW。
- 規格差異 S-1 至 S-6，以及先前的 16 項規格差異。
- Hair 以外的文獻原文核對：Dempster、Akaike、Schwarz、Kass & Raftery、Hubert & Arabie、West et al. 等。
- 授權條款未決定（`LICENSE_NOTES.md`）。
- GitHub Pages 網址要等 repo 建立後才能填入 README。

## GitHub Pages 建議設定

- Settings → Pages → Source：**Deploy from a branch**，Branch：`main`，資料夾：**`/docs`**。
- 網址的格式是 `https://<帳號>.github.io/<repo 名稱>/`，會自動轉到 `full-tutorial/gmm-skill-tutorial.html`。確認後填入 README 第 1 節。
