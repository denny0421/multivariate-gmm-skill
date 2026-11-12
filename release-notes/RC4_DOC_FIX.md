# rc4 文件修正版（2026-11-12）

**不是 rc5，也沒有改變 Skill 的行為。** 依 Hair《Multivariate Data Analysis》第 8 版第 4 章的原書核對結果，修正 4 個文字檔中的引用說法。

| ZIP | SHA-256 |
|---|---|
| rc4 原始版（保存在開發專案 `release/cowork-r43/`） | `7cb13d8b32ce3bb5491fd8d8e904e809a5ef47627e22b243bfba9ca8f27558ac` |
| **rc4 文件修正版（本 repo）** | `9437eb63dd3541d413c5197612314821576336cc2784c0d765f10ece5c1dddf2` |

## 修改的檔案（各 1 行，逐行差異見 `RC4_DOC_FIX.diff`）

| 檔案 | 修改 |
|---|---|
| `SKILL.md` | 來源說明：Hair 第 4 章是**參考並延伸**的架構，不完全相同 |
| `references/decision-tree.md` | Source boundary 加上頁碼（pp. 199–229）。區分兩件事：Hair 說常態性對一般分群影響很小（p. 211）；GMM 則假設各成分為多變量常態，所以 Stage 3 的 Gaussian 檢查是 GMM 專屬設計 |
| `references/stage4-em-math.md` | 刪除「M-step 公式與 Hair 第 4 章一致」。原書只提到以 EM 估計，沒有公式 |
| `references/stage5-interpretation.md` | 「避免任意命名」不再歸因於 Hair。原書建議依剖繪命名；不命名是本 Skill 的保守解釋原則 |

## 沒有修改

- 全部 17 個 R 程式；
- `example_data/`；
- `pending-heuristics.md`（41 項門檻，全部仍是 PENDING REVIEW）；
- 其他 references。

因此統計計算、門檻、Decision Tree、Approval Gates 都與 rc4 相同。
