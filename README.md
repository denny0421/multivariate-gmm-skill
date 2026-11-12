# multivariate-gmm：多變量 GMM 教材與 Claude Skill

這個 repo 有三個入口：

| | 入口 | 內容 |
|---|---|---|
| 1 | [**線上閱讀完整 GMM 教材**](#1-線上閱讀完整-gmm-教材) | 統計理論、Hair 六階段流程、Skill 設計、Stage 1–6 與 Penguins 結果 |
| 2 | [**下載與安裝 multivariate-gmm Skill**](#2-下載與安裝-multivariate-gmm-skill) | 在 Claude Cowork 中一步一步完成 GMM 分析 |
| 3 | [**用 Penguins 範例資料跟著操作**](#3-用-penguins-範例資料跟著操作) | 練習資料與逐步示範 |

> **版本狀態：Cowork 驗收候選版 rc4（Candidate，2026-11-12）。**
> - rc4 新增繁體中文完整報告：產生報告前會詢問語言，預設建議繁體中文；英文報告與 rc3 相同；統計程式不變。
> - 已通過 Windows（R 4.5.1）測試：
>   - 完整回歸測試 863 / 863；
>   - 中文報告測試 99 / 99；
>   - SHA-256 與環境檢查 58 / 58。
>
>   紀錄見 [`release-notes/RC4_ACCEPTANCE.md`](release-notes/RC4_ACCEPTANCE.md)。
> - rc3 已在 Cowork（R 4.3.3）完成一次 Penguins Stage 1–6 與報告產生。


## 1. 線上閱讀完整 GMM 教材

- **GitHub Pages 網址：** （待 repo 名稱確定、開啟 GitHub Pages 後填入）
- **Repo 中的檔案：** [`docs/full-tutorial/gmm-skill-tutorial.html`](docs/full-tutorial/gmm-skill-tutorial.html)。這是單一 HTML 檔，圖表與數學式都已內嵌，下載後也可以離線開啟。
- 左側目錄可以直接跳到各章，課堂上可以快速切換章節。
- 與課堂報告最相關的章節：
  - Part II：GMM、EM、BIC／AIC；
  - Part III：Skill 與 Stage 1–6；
  - Part IV：Palmer Penguins。
- Quarto 原始檔與參考文獻在 [`docs/full-tutorial/`](docs/full-tutorial/README.md)。

## 2. 下載與安裝 multivariate-gmm Skill

這是一個 Claude Skill。在 Claude Desktop App 的 **Cowork** 模式中，你只要提供一份 CSV，然後說：

> 請使用 multivariate-gmm 幫我分析這份資料。

Claude 就會一步一步帶你完成高斯混合模型（Gaussian Mixture Model, GMM）分析：預覽資料、處理缺失值、確認模型設定、估計模型、解釋結果、驗證，最後產生完整報告。

- 每個需要判斷的地方都會停下來讓你決定，而且一次只問一件事。
- 選項是編號的文字清單，你可以回答編號，也可以直接用文字回答。
- 所有數字都由 Skill 內附的 R 程式計算，Claude 不會自己估算。

**安裝步驟（摘要）**

1. 下載 [`multivariate-gmm.zip`](multivariate-gmm.zip)：在 GitHub 上點檔案，再按 **Download raw file**。
   - **不要解壓縮**。
   - 不要按綠色的「Code → Download ZIP」，那會下載整個 repo，不是 Skill。
2. 在 Claude Desktop App 開啟「程式執行與檔案建立」（Code execution and file creation）。
3. 到 **Customize → Skills** 上傳 `multivariate-gmm.zip`，確認 Skill 是開啟狀態。
4. 第一次使用時，Cowork 環境可能沒有 R。Claude 會**先問你是否同意**，同意後才從 Ubuntu 官方套件來源安裝 R 和 jsonlite。

詳細步驟見 [`INSTALL_zh-TW.md`](INSTALL_zh-TW.md)。

ZIP 的 SHA-256：`9437eb63dd3541d413c5197612314821576336cc2784c0d765f10ece5c1dddf2`。

這是 rc4 的**文件修正版**（2026-11-12）：
- 只修改 4 個文字檔（`SKILL.md` 的來源說明，以及 3 份 references），把 Hair 原書的引用改正確；
- R 程式與 rc4 逐位元相同；
- 差異見 [`release-notes/RC4_DOC_FIX.md`](release-notes/RC4_DOC_FIX.md)。

前版：

- rc4 原始 ZIP `7cb13d8b…58ac`
- rc3 `999fae41…3f15`
- rc2 `13f0983e…4f29`
- rc1 `6222f5eb…134a`

## 3. 用 Penguins 範例資料跟著操作

1. 下載 [`examples/penguins.csv`](examples/penguins.csv)。這是 Palmer Penguins 資料，344 列 × 8 欄，來源見 [`examples/DATA_SOURCE.md`](examples/DATA_SOURCE.md)。
2. 新建一個資料夾，放入 `penguins.csv`，在 **Cowork** 選擇這個資料夾。
3. 輸入：「請使用 multivariate-gmm 幫我分析 penguins.csv。」
4. 跟著 [`WALKTHROUGH_zh-TW.md`](WALKTHROUGH_zh-TW.md) 的逐步示範回答每個問題。

**各階段會看到什麼**

| 階段 | 你會看到什麼 | Claude 會停下來問你什麼 |
|---|---|---|
| 1 匯入與目標 | 資料預覽（幾列幾欄、哪些欄位有缺失） | 匯入格式是否正確、分析目標、要用哪些變數 |
| 2 資料檢查 | 缺失值統計、敘述統計與圖 | 缺失值要怎麼處理（Claude 不替你決定） |
| 3 可行性檢查 | 15 項檢查與警告 | 要不要標準化、每一列是否獨立、要試幾個群數 |
| 4 估計模型 | 各群數的 BIC／AIC 與收斂情形 | 是否接受 BIC 選出的模型 |
| 5 解釋 | 各成分的比例與平均、不確定性 | 是否進入驗證 |
| 6 驗證 | 穩定性、和其他群數比較、和已知分組的事後比對 | 是否比較其他群數、是否執行額外的重播檢查 |
| 報告 | `final_report.md`、圖、來源檔的雜湊清單 | 報告語言（繁體中文或 English） |

可能出現的狀態：

- `AWAITING_USER_APPROVAL`：等你決定；
- `BLOCKED`：資料不能這樣分析，例如你說各列不獨立；
- `REFUSED`：步驟順序不對，或缺少核准。

## 使用時請注意

- GMM 的成分不一定是真實存在的群體；和已知分組很接近，也只是事後比對的結果。
- 每一列是否彼此獨立，只能由你判斷，資料本身無法證明。
- 目前沒有 multiple imputation、缺失值直接 EM，也沒有 bootstrap 穩定性分析。
- 報告中的門檻（例如條件數 10¹⁰）是本專案自訂的經驗門檻，列在報告附錄 A，尚未經過正式審查。
- 已知的規格差異 S-1 到 S-6 尚未處理，見 [`release-notes/SPEC_ISSUES.md`](release-notes/SPEC_ISSUES.md)。

## Repo 內容

| 路徑 | 內容 |
|---|---|
| `docs/` | GitHub Pages 的發佈資料夾：`index.html` 會轉到完整教材 |
| `docs/full-tutorial/` | 完整教材：HTML、Quarto 原始檔、參考文獻與樣式 |
| `multivariate-gmm.zip` | 上傳用 Skill（Cowork R 4.3 相容版，rc4 驗收候選） |
| `skill/multivariate-gmm/` | ZIP 的原始檔案，內容與 ZIP 相同：`SKILL.md`、`references/`、`scripts/`、`example_data/` |
| `examples/` | `penguins.csv` 與資料來源說明 |
| `INSTALL_zh-TW.md`、`WALKTHROUGH_zh-TW.md` | 安裝說明與初學者逐步示範 |
| `release-notes/` | 驗收報告、測試紀錄、逐檔差異、SHA-256 清單、規格差異清單 |

## 資料與引用

- Palmer Penguins：
  - Horst, Hill & Gorman (2020), palmerpenguins R package, doi:10.5281/zenodo.3960218；
  - 原始資料：Gorman, Williams & Fraser (2014), *PLoS ONE* 9(3): e90081，CC0。
- 分析流程參考 Hair, Black, Babin & Anderson (2019)《Multivariate Data Analysis》第 8 版（Cengage Learning EMEA）第 4 章的六階段分群架構，並針對 GMM 加以延伸，不完全等同於原書。第 4 章已對照原書核對；其他文獻的原文核對尚未完成。

## 授權

授權條款尚未決定，見 [`LICENSE_NOTES.md`](LICENSE_NOTES.md)。在加入 LICENSE 檔案之前，預設保留所有權利。
