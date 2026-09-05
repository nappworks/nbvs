# PR #15 matchingRuns 逐次cursor実装の検証結果

[PR #15](https://github.com/nappworks/nbvs/pull/15) の実装を確認し、未記録だったベンチマークを実行しました。
対象コミットは `e78e00656b36864d158dd2d26f39a1f053b5d11c`、開始時の作業ツリーはcleanです。
今回追加したのは検証記録とCSVのみです。

## 実装の確認

- `matchingRunsItems(value, left, right)` はrankで出現範囲を求め、cursorの
  `nextOccurrence`を範囲先頭に設定し、`nextSelectUnchecked`で位置を昇順に復元します。
  隣接位置を極大な半開区間にまとめます。
- `matchingRuns` / `collectMatchingRuns` は既存APIのままこのiteratorを使用します。
- 比較専用の `matchingRunsCursor*` APIは残っていません。
- `bitRuns*` 実装の追加変更はありません。
- 既存テストで単純例、空入力、全一致、不一致、不正範囲、範囲指定、word境界、
  固定seedのランダム入力とnaive scanの一致を確認しました。

## 環境と測定条件

- Nim 2.2.10 (`bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef`)、Nimble 0.22.2
- GCC 15.2.0、Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- Intel Core i5-8365U @ 1.60GHz、4 cores / 8 threads、AVX2/BMI2対応
- Cバックエンド、threads:on。全体テストはORC・debug、個別テストはORCとARC・debug。
- ベンチマークはARC・release、scalarと `-d:nbvsSimd` を順番に実行。
- 1,000,000行、target=7、一致率約25%、run length 1/4/16/64/256/1024/4096。
- 各条件21反復の中央値。明示的なウォームアップはありません。
- 同一データ・同一反復でiterator、seq、regular select、sequential cursor selectの順に測定。
  matrix構築と出現数の事前計算は計測外、cursor初期化とrun構成は計測内です。
- 通常版測定開始時に個別テストのコンパイル・実行と環境情報取得が短時間重なりました。
  SIMD版測定中は他のビルド・テストを実行していません。

## 検証コマンドと結果

個別テストはORC、ARCともに成功しました。

```sh
nim c --nimcache:/tmp/nbvs-pr15-test-cache --out:/tmp/nbvs-pr15-test -r tests/twavelet_matching_runs.nim
nim c --mm:arc --nimcache:/tmp/nbvs-pr15-test-arc-cache --out:/tmp/nbvs-pr15-test-arc -r tests/twavelet_matching_runs.nim
```

全体テストは通常版・SIMD版ともに `OK all` で成功しました。
既定の `~/.nimble` は書き込み制限があるため、前回の検証で取得済みの
`/tmp/nbvs-pr14-nimble` を使用し、インストール済みコンパイラとofflineを指定しました。

```sh
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble test
nimble --offline --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble testSimd
```

ベンチマークのビルド・実行は両方成功しました。通常版CSVは標準出力から保存しました。

```sh
nim c --path:src -d:release --mm:arc --nimcache:/tmp/nbvs-pr15-bench-cache --out:/tmp/nbvs-pr15-bench -r benchmarks/wm_matching_runs_perf.nim
nim c --path:src -d:release -d:nbvsSimd --mm:arc --nimcache:/tmp/nbvs-pr15-bench-simd-cache --out:/tmp/nbvs-pr15-bench-simd benchmarks/wm_matching_runs_perf.nim
/tmp/nbvs-pr15-bench-simd > benchmarks/results/wm_matching_runs_pr15_simd.csv
```

公開モジュールのドキュメント生成も成功しました。

```sh
nim doc --nimcache:/tmp/nbvs-pr15-doc-cache --project --outdir:/tmp/nbvs-pr15-doc src/nbvs.nim
```

成功したテスト・ベンチマーク・ドキュメント生成のログにWarning/Errorはありません。
`*.nimble` は未変更のため `nimble check` は実行していません。

## 測定結果

生データ: [通常版](wm_matching_runs_pr15_scalar.csv)、[SIMD版](wm_matching_runs_pr15_simd.csv)。
倍率は比較元の時間 / `matchingRunsItems` の時間です。1より大きいほどiteratorが高速です。

| Backend | run length | iterator p50 ms | seq p50 ms | 対regular倍率 | 対cursor倍率 |
| --- | ---: | ---: | ---: | ---: | ---: |
| scalar | 1 | 12.861 | 15.210 | 5.040 | 1.007 |
| scalar | 4 | 13.151 | 13.782 | 5.171 | 1.019 |
| scalar | 16 | 12.894 | 12.827 | 5.234 | 1.011 |
| scalar | 64 | 12.739 | 12.238 | 5.274 | 0.992 |
| scalar | 256 | 13.302 | 12.624 | 4.955 | 0.972 |
| scalar | 1024 | 13.027 | 13.133 | 5.252 | 0.941 |
| scalar | 4096 | 12.318 | 12.524 | 5.561 | 1.011 |
| SIMD | 1 | 13.649 | 15.454 | 3.046 | 0.935 |
| SIMD | 4 | 12.780 | 13.254 | 3.385 | 0.998 |
| SIMD | 16 | 13.111 | 13.168 | 3.175 | 0.962 |
| SIMD | 64 | 12.666 | 12.591 | 3.175 | 0.961 |
| SIMD | 256 | 13.468 | 13.317 | 2.978 | 0.930 |
| SIMD | 1024 | 12.405 | 12.093 | 3.035 | 0.958 |
| SIMD | 4096 | 12.082 | 12.048 | 3.176 | 1.050 |

通常selectからrunを構成する方法より、全条件で高速でした。
逐次cursorから直接runを構成する方法とは概ね同程度ですが、scalarでは最大約6.2%、
SIMDでは最大約7.5%遅い条件があります。
run length 1ではseq版に結果250,000件を格納する追加コストが見られます。
run lengthを増やしても一致数は約250,000件のままであり、iteratorの所要時間もほぼ一定です。

[以前のdepth-first実装の測定](wm_matching_runs_depth_first_performance.md) に記載された
長いrunでの約100ms以上の所要時間に対し、今回は約12～13msでした。
ただし以前のコミットを同時に再測定していないため、別実行の数値から厳密な改善率は算出しません。
固定実行順序・明示的なウォームアップなし・単一WSL2環境の測定であり、数％の差には揺らぎが含まれます。

## ドキュメント、互換性、残課題

READMEの英語版・日本語版とコード内ドキュメントコメントは未変更です。
今回の記録追加による両言語の仕様差はありません。APIドキュメントの生成物は `/tmp` に保存しました。
公開API、実装、依存関係、実行時性能、メモリ使用量への追加の変更はありません。移行作業は不要です。

PR本文の実装確認・テスト・ベンチマークについて残課題なし。
メモリ使用量、他OS・CPU、C++/JavaScriptバックエンドは未検証です。
今回の測定は旧実装との同条件A/B比較や、数％の性能差の再現性までは保証しません。
