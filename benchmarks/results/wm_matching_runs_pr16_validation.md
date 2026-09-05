# PR #16 terminal-to-root interval lifting 検証結果

[PR #16](https://github.com/nappworks/nbvs/pull/16) の最新コミット
`3c189683b7e54adc8063bcd88fb13f4b47fec058` を確認し、未実施の検証・測定を実行しました。
開始時の作業ツリーはcleanでした。

## 修正内容

実装はPR本文のterminal intervalへのrank写像、両端selectによる連続判定、
非連続区間の二分、DFSによる位置順の復元、隣接区間の結合に対応しています。
公開APIと範囲指定、結果順序は維持しています。永続補助構造は追加していません。

ただし `let bits = wm.levels[level]` が、Nim 2.2.10のARC・release生成Cで
`SuccinctBitVector` の `eqcopy` を呼び、内部seqを複製していました。
100万行の初回測定は最初の条件の完了前に中断しました。
rank/select呼び出しを `wm.levels[level]` の直接参照へ変更し、
iterator・seq版双方の生成Cから該当コピーが消えたことを確認しました。
unsafeな参照や新しい依存関係は導入していません。

テストには明示的なbitWidth=0、64bit最大値・最上位bit、全範囲のnaive比較、
iteratorの途中終了、Viewの範囲指定と互換別名の比較を追加しました。
既存の全ゼロ入力は自動推定でbitWidth=1となるため、0bitテストを補いました。
これらは境界・互換性の検証です。コピー問題の性能回帰は下記ベンチマークと
生成Cで確認し、環境依存の時間閾値を単体テストには設けていません。

## 環境・測定方法

- Nim 2.2.10、GCC 15.2.0、Linux 5.15.146.1-microsoft-standard-WSL2 x86_64。
- Intel Core i5-8365U、4 cores / 8 threads、AVX2/BMI2対応。
- Cバックエンド、threads:on。個別テストはORCとARC、全体テストはORC・debug。
- ベンチマークはARC・release。scalarとSIMDを順番に実行し、他のビルド・テストと重ねていません。
- 1,000,000行、target=7、bitWidth=3、一致率約25%、各条件21反復の中央値。
- run lengthは1/4/16/64/256/1024/4096。明示的なウォームアップなし。
- iterator、seq、sequential cursorの固定順序。構築は測定外、cursor初期化とrun構成は測定内。
- 同一実行のcursor比較であり、過去PRの別実行値から倍率を算出していません。

## 検証コマンド

以下は修正後にすべて成功しました。全体テストは通常版・SIMD版とも `OK all`、
成功したコンパイル・テスト・ドキュメント生成にWarning/Errorはありません。

```sh
nim c --nimcache:/tmp/nbvs-pr16-focused --out:/tmp/nbvs-pr16-focused-test -r tests/twavelet_matching_runs.nim
nim c --mm:arc --nimcache:/tmp/nbvs-pr16-arc --out:/tmp/nbvs-pr16-arc-test -r tests/twavelet_matching_runs.nim
nim c --mm:arc --nimcache:/tmp/nbvs-pr16-views --out:/tmp/nbvs-pr16-views-test -r tests/tstructure_views.nim
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble test
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble testSimd
nim doc --nimcache:/tmp/nbvs-pr16-doc-cache --project --outdir:/tmp/nbvs-pr16-doc src/nbvs.nim
nim c --path:src -d:release --mm:arc --nimcache:/tmp/nbvs-pr16-bench-cache --out:/tmp/nbvs-pr16-bench benchmarks/wm_matching_runs_perf.nim
nim c --path:src -d:release --mm:arc -d:nbvsSimd --nimcache:/tmp/nbvs-pr16-bench-simd-cache --out:/tmp/nbvs-pr16-bench-simd benchmarks/wm_matching_runs_perf.nim
/tmp/nbvs-pr16-bench > benchmarks/results/wm_matching_runs_pr16_scalar.csv
/tmp/nbvs-pr16-bench-simd > benchmarks/results/wm_matching_runs_pr16_simd.csv
git diff --check
```

初回の `nimble --version` はバージョンを表示した後、既定の `~/.nimble` への
書き込み制限で終了コード1になりました。検証には既存の `/tmp/nbvs-pr14-nimble`
とofflineを指定しました。Nimbleはそこで取得済みの同版コンパイラを使用しました。
`*.nimble` は未変更のため `nimble check` は省略しました。

## 100万行の測定結果

生データ: [scalar](wm_matching_runs_pr16_scalar.csv)、[SIMD](wm_matching_runs_pr16_simd.csv)。
倍率はcursor時間 / iterator時間で、1を超えるとiteratorが高速です。

| backend | run length | iterator p50 ms | seq p50 ms | cursor p50 ms | 対cursor倍率 |
| --- | ---: | ---: | ---: | ---: | ---: |
| scalar | 1 | 92.630 | 96.181 | 13.541 | 0.146 |
| scalar | 4 | 71.542 | 72.610 | 13.951 | 0.195 |
| scalar | 16 | 34.414 | 34.301 | 12.408 | 0.361 |
| scalar | 64 | 14.271 | 14.479 | 12.455 | 0.873 |
| scalar | 256 | 5.272 | 5.143 | 13.970 | 2.650 |
| scalar | 1024 | 1.616 | 1.560 | 12.522 | 7.747 |
| scalar | 4096 | 0.493 | 0.481 | 12.343 | 25.041 |
| simd | 1 | 66.191 | 67.773 | 12.718 | 0.192 |
| simd | 4 | 50.737 | 51.354 | 13.681 | 0.270 |
| simd | 16 | 24.271 | 24.562 | 13.148 | 0.542 |
| simd | 64 | 8.270 | 8.442 | 13.259 | 1.603 |
| simd | 256 | 2.884 | 2.907 | 13.292 | 4.610 |
| simd | 1024 | 0.913 | 0.894 | 13.316 | 14.588 |
| simd | 4096 | 0.302 | 0.284 | 13.375 | 44.359 |

長いrunではscalarで最大約25倍、SIMDで最大約44倍高速でした。
一方、scalarのrun length 1/4/16/64、SIMDの1/4/16ではcursorより遅く、
最短runではそれぞれ約6.8倍・5.2倍の時間が掛かります。
全入力での高速化ではなく、長いrunをまとめて復元する方式のトレードオフです。

## コピー除去の前後比較

100万行の修正前測定は未完了のため比較値を示しません。
修正前バイナリと再ビルド後バイナリで10,000行・5反復の同じ測定も実施しました。

```sh
NBVS_MATCHING_RUNS_ROWS=10000 NBVS_MATCHING_RUNS_REPEATS=5 /tmp/nbvs-pr16-bench
```

生データ: [修正前](wm_matching_runs_pr16_before_10000.csv)、
[修正後](wm_matching_runs_pr16_after_10000.csv)。
run length 1のiterator中央値は6.434msから0.932msへ短縮しました。
小規模の参考測定であり、実行時点が異なるため厳密な統計的比較ではありません。

## ドキュメント・互換性・残課題

READMEの英語・日本語双方にAPI、順序保証、方式、性能上の制約と測定へのリンクを追加し、
同等の内容であることを確認しました。日本語APIコメントには計算量とコピー回避理由を追記しました。
bit幅B、一致数Mに対してrankはO(B)回、selectは最悪O(B*M)回、
補助stackはO(1 + log(M + 1))です。各rank/selectの実行コストは別途掛かります。
seq版は返却run数に比例する出力領域を必要とします。

公開API・保存形式・依存関係・対応OSへの変更はなく、移行作業は不要です。
コピー除去により一時確保とメモリ転送を削減しましたが、RSSの実測は行っていません。
他OS・CPU、C++/JavaScriptバックエンドは未検証です。
単一WSL2環境・固定実行順・明示的ウォームアップなしの結果であり、汎用的な倍率は保証しません。
短いrunでの性能低下は既知の制約として残ります。PRの方式変更、テスト、測定・記録は完了しました。
