# PR #14 逐次 select cursor 検証結果

[PR #14](https://github.com/nappworks/nbvs/pull/14) 本文の未実施コマンドを実行した結果です。
実装の変更は行っていません。既存の測定結果は前の実装の記録として保持します。

## 環境と測定条件

- 対象コミット: `488bafa14c00b6cba7e969fcc7d112503d9eb72e`
- 開始時の作業ツリー: clean
- Nim: 2.2.10 (`bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef`)
- Nimble: 0.22.2
- Cコンパイラ: GCC 15.2.0
- OS: Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- CPU: Intel Core i5-8365U @ 1.60GHz、AVX2/BMI2対応
- テスト: Cバックエンド、ORC、threads:on、デバッグビルド
- ベンチマーク: Cバックエンド、ARC、threads:on、release
- 入力: 1,000,000行、`index mod cardinality` の周期分布、対象値は `cardinality - 1`
- cardinality: 4 / 100 / 1,000 / 10,000、出現数: 250,000 / 10,000 / 1,000 / 100
- 各条件21反復の中央値。明示的なウォームアップはなし。
- 各反復の順序はnormal、prepared、sequential固定。
- preparedの初期化は計測外、sequentialの初期化は計測内（既存ベンチマークの仕様）。
- 通常版とSIMD版を逐次実行し、測定中に他の検証コマンドは実行していません。

## 検証コマンドと結果

cursor個別テストは以下の2件とも成功しました。

```sh
nim c --nimcache:/tmp/nbvs-pr14-bit-cache --out:/tmp/nbvs-pr14-bit -r tests/tbit_vector_select_cursor.nim
nim c --nimcache:/tmp/nbvs-pr14-wavelet-cache --out:/tmp/nbvs-pr14-wavelet -r tests/twavelet_select_cursor.nim
```

PR指定の全体テストはどちらも `OK all` で成功しました。
Nimbleの既定保存先への書き込み制限とコンパイラ自動解決の失敗を回避するため、
保存先とインストール済みコンパイラを明示しました。公式パッケージ一覧の取得には接続許可が必要でした。
Nimbleが最終的に使用したコンパイラも上記と同じバージョン・git hashです。

```sh
nimble --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble test
nimble --nim:/home/vscode/.choosenim/toolchains/nim-2.2.10/bin/nim --nimbleDir:/tmp/nbvs-pr14-nimble testSimd
```

ベンチマークは両方ともビルド・実行成功しました。生成物は `/tmp` に出力しました。

```sh
nim c --path:src -d:release --mm:arc --nimcache:/tmp/nbvs-pr14-bench-cache --out:/tmp/nbvs-pr14-bench -r benchmarks/wm_select_cursor_perf.nim
nim c --path:src -d:release -d:nbvsSimd --mm:arc --nimcache:/tmp/nbvs-pr14-bench-simd-cache --out:/tmp/nbvs-pr14-bench-simd -r benchmarks/wm_select_cursor_perf.nim
```

APIドキュメント生成も成功しました。

```sh
nim doc --nimcache:/tmp/nbvs-pr14-doc-cache --project --outdir:docs/api src/nbvs.nim
```

成功した全体テスト・ベンチマーク・ドキュメント生成のログにWarning/Errorはありませんでした。
初回のNimble環境解決失敗は終了コード0を返したため、成功判定にはログの `OK all` を確認しています。

## 測定結果

生データ: [通常版](wm_select_cursor_pr14_scalar.csv)、[SIMD版](wm_select_cursor_pr14_simd.csv)。
時間は全出現位置を取得する処理の中央値（ns）、倍率は比較元時間 / sequential時間です。

| Backend | Cardinality | Normal ns | Prepared ns | Sequential ns | 対normal倍率 | 対prepared倍率 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 4 | 40867240 | 33603618 | 8346900 | 4.896 | 4.026 |
| scalar | 100 | 9422357 | 8055719 | 1356537 | 6.946 | 5.938 |
| scalar | 1,000 | 1204233 | 988927 | 455912 | 2.641 | 2.169 |
| scalar | 10,000 | 199105 | 165405 | 112303 | 1.773 | 1.473 |
| simd | 4 | 26656577 | 19703310 | 7794937 | 3.420 | 2.528 |
| simd | 100 | 5017510 | 3424280 | 1021483 | 4.912 | 3.352 |
| simd | 1,000 | 663754 | 503141 | 357429 | 1.857 | 1.408 |
| simd | 10,000 | 85907 | 61205 | 62205 | 1.381 | 0.984 |

通常selectとの比較では全条件で高速化しました。preparedとの比較では、
SIMD・cardinality 10,000で0.984倍（約1.6%遅い）となりました。
他の条件では逐次state再利用による追加の改善が観測されました。

[以前の測定](wm_select_cursor_performance.md) にある2.0倍目標については、
cardinality 1,000は通常版で達成、SIMD版で未達、cardinality 10,000は両方未達です。
今回のnormalも以前の測定値と異なるため、別実行間の時間差をそのまま実装の改善率とは扱いません。
明示的なウォームアップや実行順序のランダム化を行っていない単一環境の結果であり、
約1.6%の差が再現するかは未確認です。

## 互換性と残課題

今回追加したのは検証記録とCSVのみで、公開API・実装・依存関係・READMEに変更はありません。
READMEの英語版・日本語版およびコード内ドキュメントコメントも未変更です。
生成したAPIドキュメントはgit管理対象外です。

PR指定の検証はすべて完了しました。メモリ使用量、他OS・CPU、他バックエンドでの動作は未測定です。
高cardinalityでの2.0倍目標、およびSIMD・cardinality 10,000でのpreparedに対する性能差は、
追加の性能検討事項として残ります。
