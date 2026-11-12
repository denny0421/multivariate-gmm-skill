# 完整版教材

這是完整的統計與實作教材，同時作為課堂展示、課後閱讀和 GitHub 上的正式教學文件。內容包括：
- 多變量常態分布；
- EM 推導；
- 模型選擇；
- 缺失值處理；
- Skill 設計與 Stage 1–6；
- 兩個真實資料案例（Palmer Penguins、UCI Automobile）。

## 檔案

- `gmm-skill-tutorial.html`：可以離線開啟的完整網頁。圖表與數學式都已內嵌，左側目錄可以直接跳到各章。
- `gmm-skill-tutorial.qmd`：Quarto 原始檔。
- `references.bib`：參考文獻。
- `tutorial.css`：樣式。
- 上一層的 `../index.html`：GitHub Pages 的入口，會自動轉到這份教材。

## 注意事項

- 教材是初版，**尚未完成學術最終審查**。部分文獻（包括 Hair 等人教科書的頁碼）還在核對中，見第 24 章「已完成驗收與尚存限制」。
- QMD 會讀取開發專案中未公開的正式分析結果與輔助程式，無法在這個 repo 單獨重新產生；請使用 HTML。
- 教材中的 `.claude/skills/...` 路徑是開發環境（Claude Code）的寫法，與 Cowork 的使用方式無關。
