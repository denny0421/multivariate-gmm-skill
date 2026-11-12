# multivariate-gmm Skill：Claude Cowork 使用說明（R 4.3 相容版）

> **目前狀態：** 這個版本已在 Windows 開發環境通過回歸測試，**還沒有在 Cowork 完成驗收**。課堂使用前，老師或助教會先在 Cowork 實際測試一次。

## 需要的檔案

1. `multivariate-gmm.zip`：Skill 本體，**不要解壓縮**。
2. `penguins.csv`：練習資料，344 列 × 8 欄（在 repo 的 `examples/` 資料夾）。
3. 這份說明。

## 1. 安裝 Skill

1. 打開 Claude Desktop App，確認已開啟「程式執行與檔案建立」（Code execution and file creation）。
2. 到 **Customize → Skills** 上傳 `multivariate-gmm.zip`，確認 `multivariate-gmm` 是開啟狀態。
3. 如果以前裝過舊版，請先移除舊版，再上傳這個版本。

## 2. 準備資料夾

在電腦上新建一個資料夾，例如 `gmm-practice`，把 `penguins.csv` 放進去。分析結果會寫在這個資料夾的 `results/` 底下，原本的 `penguins.csv` 不會被修改。

## 3. 在 Cowork 開始分析

切到 **Cowork**，選擇剛才的資料夾，輸入：

> 請使用 multivariate-gmm Skill 幫我分析 penguins.csv。

接下來 Claude 會一步一步引導你，你不需要輸入任何指令。

Claude 每次只問目前需要決定的事，並用一兩句話說明每個選項。選項是編號的文字清單，你可以回答編號，也可以直接用文字回答；它們不一定會顯示成可以點的按鈕。你做完決定後，Claude 會用一句話複述並記錄下來。

1. **檢查環境。** Claude 會檢查有沒有 R、jsonlite、能不能畫圖，以及 SHA-256 檢查是否正常。
2. **安裝 R（第一次才需要）。** 如果環境裡沒有 R，Claude 會**先問你同意後**，才從 Ubuntu 官方套件來源安裝 R 和 jsonlite。安裝需要幾分鐘。請看清楚 Claude 說明要安裝什麼之後再回答。
3. **預覽資料。** Claude 會把匯入格式當作一組一起確認：標題列、分隔符、編碼和缺失值標記（penguins.csv 是：有標題列、逗號分隔、UTF-8、缺失值標記 NA）。
4. **分析目標與變數。** 先問目標（分群或描述分布），再問要用哪些變數、哪一欄是要留到最後比對的已知分組。例如：「分群；用 bill_length_mm、bill_depth_mm、flipper_length_mm、body_mass_g，species 留到最後比對。」
5. **缺失值選單。** Claude 會列出幾種處理方式，各用一兩句話說明影響。請自己選，例如「用 complete-case」。
6. **Stage 3 確認。** Claude 會依序問三件事：要不要標準化 → 每一列是否彼此獨立 → G 的範圍。最後整理成一份設定，請你核准。例如：標準化選 z-score；獨立性選「工作假設」並寫一句原因，例如「同一島嶼或年份的企鵝可能不完全獨立」；G 選 1 到 5。
7. **Stage 4–6 和報告。** 每一步看完結果再回覆。Stage 6 前，Claude 可能會問你要不要和另一個 G 比較（例如 AIC 偏好的 G）。
8. **報告語言。** 產生報告前，Claude 會問你要用哪種語言：1. 繁體中文（預設建議）、2. English。兩種語言的數字和警告完全相同，只有文字不同；之後也可以再產生另一種語言的版本，不需要重新估計模型。報告是 `results/` 底下的 `final_report.md`，Claude 會告訴你完整路徑。圖表中的文字目前是英文，中文報告會在每張圖下附中文圖說。

## 注意事項

- Claude 每次停下來問你，都是需要你自己判斷的地方。如果你回「你決定」，Claude 會再說明一次利弊，請你自己選。
- 出現 WARNING 代表可以繼續，但有限制，報告會保留這些限制；BLOCKED 代表資料不能這樣分析，核准也無法跳過。
- **以下情況請停下來回報老師或助教，不要讓 Claude 改用其他方式計算：**
  - 安裝 R 失敗；
  - 出現 `ENV_SHA256_UNAVAILABLE`；
  - 出現其他錯誤。
- **新開一個 Cowork 任務後是否要重裝 R，目前還沒確認。** 如果 Claude 又說找不到 R，照第 3 節的第 2 步再同意一次即可。
- GMM 的成分不一定是真實的群體；和物種很接近，也只是事後比對的結果。
- 報告和紀錄檔會寫入資料夾路徑。分享之前，請確認裡面沒有你不想公開的資訊。

## 資料來源

Horst AM, Hill AP, Gorman KB (2020). *palmerpenguins: Palmer Archipelago (Antarctica) penguin data.* R package version 0.1.0. doi:10.5281/zenodo.3960218。原始資料：Gorman KB, Williams TD, Fraser WR (2014). *PLoS ONE* 9(3): e90081，授權為 CC0。
