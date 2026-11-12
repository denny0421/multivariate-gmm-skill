# 授權待決事項（尚未選定授權條款）

這個 repo 目前**沒有 LICENSE 檔案**。在作者確認下列事項並選定條款之前，預設保留所有權利，他人可以閱讀，但沒有明確的再利用許可。

| 內容 | 待確認事項 | 可考慮的選項（僅供參考，尚未決定） |
|---|---|---|
| Skill 程式（`skill/`、ZIP 內的 R 腳本） | 作者與共同作者是否同意公開；是否含有他人程式碼。依賴的 `jsonlite` 是 MIT 授權，R 本身是 GPL，本專案程式透過 R 執行，並未複製它們的原始碼 | MIT、Apache-2.0 或 GPL-3.0 |
| 教材（`docs/`） | 作者署名方式（教材已移除作者占位文字，未填入姓名）；引用 Hair et al. 等書籍的段落是否只有引用、沒有大段轉載；HTML 內嵌的 Quarto、Bootstrap、Mermaid 等前端程式庫各有自己的授權 | CC BY 4.0 或 CC BY-NC 4.0 |
| Palmer Penguins 資料（`examples/penguins.csv`） | 原始資料為 CC0；palmerpenguins 套件要求引用 | 保留 CC0，並在 README 引用 |
| UCI Automobile 的衍生結果（只出現在教材表格中，repo 不含原始資料） | UCI 資料集的授權條款與引用方式（教材引用 doi:10.24432/C5B01C） | 依 UCI 標示的條款引用 |
| 學術判斷與核准紀錄 | 教材中的開發紀錄是否適合公開 | — |

確認後，在 repo 根目錄加入 `LICENSE`（程式），必要時再加 `LICENSE-docs`（教材），並更新 README 的「授權」一節。
