# PR #17 ハイブリッド matchingRuns 検証結果

[PR #17](https://github.com/nappworks/nbvs/pull/17) の先頭コミット
`2088d834cdce48c548c48ea04b005c56adb8708b` を対象に、未実施のテストと測定を実行しました。
開始時の作業ツリーはcleanで、PRの追加コメントはありませんでした。

## 変更・設計判断

既存のハイブリッド実装を確認し、初期定数96 / 32を維持しました。
96は両端selectによる連続判定の回数で、select呼び出し自体は最大192回です。
32要素以上の物理区間がprobeで見つかればliftingを選び、細分化が続けばcursorを選びます。
probeが全候補を処理し終えた場合はliftingを使用します。
部分範囲はterminal intervalからcursorの出現番号に変換し、範囲内のみ列挙します。

短runの退化抑制と長runの利点を測定で確認できたため、この単一環境に合わせた
閾値の調整は行いませんでした。scalarのrun長64はcursorより遅いという制約があります。
公開API、結果順序、保存形式、依存関係は変更していません。移行作業は不要です。
永続補助構造はなく、query中のcursorとDFS stackのみを使用します。
Nimの所有型levelをコピーすると内部seqの複製が起こり得るため、直接参照を維持しました。
RSSの実測は行っていません。

PRで削除されていた日本語公開APIコメントを復元し、計算量を追記しました。
READMEの英語・日本語を同等のハイブリッド方式の説明と本結果へのリンクに更新しました。
追加テストはrun長1/4/16/31/32/64/256、bit幅3/64、所有型とView、
部分範囲・空範囲・1要素範囲・iterator途中終了・互換別名をnaive走査と比較します。
既存テストで空入力、0bit、範囲外の値、不正範囲、固定seed乱数も検証します。

## 検証

以下はすべて成功しました。全体テストは両方とも `OK all`、警告・エラーなしです。

```sh
nim c --nimcache:/tmp/nbvs17-test-cache --out:/tmp/nbvs17-test -r tests/twavelet_matching_runs.nim
nim c --mm:arc --nimcache:/tmp/nbvs17-arc-cache --out:/tmp/nbvs17-arc -r tests/twavelet_matching_runs.nim
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble test
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble testSimd
nim doc --project --nimcache:/tmp/nbvs17-doc-cache --outdir:/tmp/nbvs17-doc src/nbvs.nim
nim c --path:src -d:release --mm:arc --nimcache:/tmp/nbvs17-bench-cache --out:/tmp/nbvs17-bench benchmarks/wm_matching_runs_perf.nim
nim c --path:src -d:release --mm:arc -d:nbvsSimd --nimcache:/tmp/nbvs17-bench-simd-cache --out:/tmp/nbvs17-bench-simd benchmarks/wm_matching_runs_perf.nim
/tmp/nbvs17-bench > /tmp/nbvs17-initial.csv
cp /tmp/nbvs17-initial.csv benchmarks/results/wm_matching_runs_pr17_scalar.csv
/tmp/nbvs17-bench-simd > benchmarks/results/wm_matching_runs_pr17_simd.csv
git diff --check
```

初回の `nimble --version` はv0.22.2表示後、既定の `~/.nimble` への書き込み制限で
終了コード1になりました。以降は既存の書き込み可能なNimbleディレクトリとofflineを使用し、
依存取得なしで成功しています。nimbleファイルは未変更で `nimble check` は省略しました。
ライブラリのためアプリケーション用buildではなく、全体テストとベンチのビルドを実施しました。

## 測定条件

- Nim 2.2.10、GCC 15.2.0、Linux 5.15.146.1-microsoft-standard-WSL2、x86_64。
- Intel Core i5-8365U、4 cores / 8 threads、AVX2/BMI2対応。
- Cバックエンド、threads:on。テストはORC/debug、個別テストはARCも実行。
- ベンチはARC/release、100万行、bit幅3、target=7、一致率約25%、21反復の中央値。
- 構築は測定外、cursor初期化とrun構成は測定内。明示的ウォームアップなし。
- iterator、seq、cursorの固定順。scalarとSIMDの実行はビルド・テストと重ねず実施。
- scalarはコメント復元前の実行ですが、実行コードは同一です。
- 倍率は同じ実行でのcursor時間 / hybrid iterator時間。過去PRとの直接倍率比較はしていません。

## 測定結果

生データ: [scalar](wm_matching_runs_pr17_scalar.csv)、[SIMD](wm_matching_runs_pr17_simd.csv)。

| backend | run長 | iterator p50 ms | seq p50 ms | cursor p50 ms | 対cursor倍率 |
| --- | ---: | ---: | ---: | ---: | ---: |
| scalar | 1 | 13.723 | 16.360 | 13.646 | 0.994 |
| scalar | 4 | 13.601 | 14.078 | 13.955 | 1.026 |
| scalar | 16 | 12.914 | 13.181 | 12.836 | 0.994 |
| scalar | 64 | 14.101 | 14.574 | 12.481 | 0.885 |
| scalar | 256 | 4.926 | 4.801 | 13.053 | 2.650 |
| scalar | 1024 | 1.645 | 1.546 | 12.446 | 7.567 |
| scalar | 4096 | 0.472 | 0.477 | 12.131 | 25.693 |
| simd | 1 | 13.494 | 16.930 | 13.508 | 1.001 |
| simd | 4 | 13.401 | 14.649 | 13.574 | 1.013 |
| simd | 16 | 13.884 | 13.187 | 13.158 | 0.948 |
| simd | 64 | 8.285 | 8.579 | 12.585 | 1.519 |
| simd | 256 | 2.893 | 2.798 | 12.596 | 4.354 |
| simd | 1024 | 0.865 | 0.854 | 12.855 | 14.860 |
| simd | 4096 | 0.301 | 0.284 | 12.566 | 41.746 |

短runではcursorに近い時間となり、長runではliftingの優位性を維持しました。
sequence版は結果の確保・格納を含むため、短runでiterator版より遅くなります。

## 既知の制約

scalarのrun長64ではcursorより約13%遅く、heuristicは常に最速とは限りません。
混在run分布、他のbit幅での性能、他OS・CPU、C++/JavaScriptは未測定・未検証です。
固定順序・ウォームアップなしの単一環境測定であり、倍率を一般化できません。
要求されたテスト・測定・文書更新は完了しました。
