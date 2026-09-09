# SBV / QV パフォーマンス比較

> **再測定待ち**
>
> 2026-09-09 に SBV の SIMD 専用 `blockPairPrefix` を廃止し、scalar/SIMD で
> rank/select 補助構造を統一しました。この変更後は SBV SIMD の rank/build 性能と
> 補助容量が変わるため、下記の既存数値および `sbv_quad_vector_simd.csv` は
> 旧 `blockPairPrefix` ありの実装で取得した参考値です。
> `nimble benchSbvQv` / `nimble benchSbvQvSimd` を再実行し、CSV と本ページを更新してから
> 最終結果として扱います。

## 測定条件

- 実行日: 2026-09-09
- CPU: Intel Core i5-8365U（4 cores / 8 threads、AVX2/BMI2）
- OS: Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- Nim: 2.2.10
- C compiler: GCC 15.2.0
- memory manager: ARC
- compiler options: `-d:release --mm:arc`
- SIMD追加option: `-d:nbvsSimd`（生成Cコードには `-mavx2 -mbmi2` が適用される）
- 測定: 固定seed、warmup 1回、測定7回のp50
- query workload: 各operation 100,000回
- サイズ: 65,536 / 1,048,576 / 16,777,216 symbols

分布は `uniform`（各値25%）、`sparse`（0が97%）、`dense`
（0が1%、1..3が各約33%）、`skewed`（70/20/8/2%）です。同じ4値symbol列を
両構造へ入力し、SBVにはsymbolの下位bitを格納しました。access/rank/selectは同数の
queryを実行し、rank/selectのQV symbolとSBV bitは同じquery symbolから決定しています。

## 実行方法

```sh
nimble benchSbvQv
nimble benchSbvQvSimd
```

実装は [`benchmarks/sbv_quad_vector_comparison.nim`](../sbv_quad_vector_comparison.nim)、
生結果は [scalar CSV](sbv_quad_vector_scalar.csv) と
[SIMD CSV](sbv_quad_vector_simd.csv) に保存しています。

現行ベンチマークでは補助容量を以下に分けて出力します。

- `rank_only_aux_bytes`: rank 専用補助領域
- `select_only_aux_bytes`: select 専用補助領域
- `shared_aux_bytes`: rank/select 共用補助領域
- `total_aux_bytes`: 上記3つの合計

SBV は scalar/SIMD とも旧 `wordPairPrefix` / `blockPairPrefix` を自動生成せず、
階層 `selectStorage` を rank/select で共用します。そのため現行実装では
`rank_only_aux_bytes == 0`、`shared_aux_bytes == selectStorage` です。

## 旧実装での結果概要

以下は SIMD 専用 `blockPairPrefix` を廃止する前の参考値です。

16,777,216 symbolsの測定では、scalar QVのbuildは7.81–8.82 ms
（1.90–2.15 Gsymbols/s）、SIMD QVは2.55–3.81 ms
（4.41–6.58 Gsymbols/s）でした。QVのSIMD化によりbuildは約2.1–3.4倍に高速化しています。

同サイズのQV queryは、scalarでaccess 5.38–11.94 ns、rank
106.73–113.66 ns、select 239.13–313.03 nsでした。SIMDではaccess
7.30–13.24 ns、rank 77.55–90.89 ns、select 211.51–261.91 nsです。
accessはpayload readのみなのでSIMD化の対象ではなく、実行時の揺らぎが見えます。
rank/selectは全分布でSIMD版がscalar版を短縮しました。

SBVとQVは表現能力とpayload幅が異なるため、単純な倍率は同一処理の高速化を意味しません。
同じsymbol数ではSBVのpayloadがQVの半分であり、SBVのbuild/rank/selectはいずれも
QVより短時間でした。CSVには比較のため、symbolあたりとpayload byteあたりのbuild
throughputを両方記録しています。

## 容量

16,777,216 symbolsのQV payloadは4,194,304 bytes、rank補助は262,144 bytes
（6.25%）でした。select補助は分布により65,536–65,560 bytesで、合計補助容量は
327,680–327,704 bytes（約7.8125%）です。末尾wordの丸めにより分布ごとに最大24 bytes
の差があります。

旧測定では scalar SBV の共用 `selectStorage` は74,912 bytesでした。
旧 SIMD 測定はこれに加えて65,536 bytesの `blockPairPrefix` を保持していましたが、
現行実装ではこの SIMD 専用領域を廃止しています。再測定後は scalar/SIMD とも
同じ補助構造容量になる想定です。

## 注意事項

WSL2上の単一ホストでの測定です。特に65,536 symbolsのbuildは測定時間が短いため、
絶対値や数%の差を評価する用途では、試行回数または反復build回数を増やして
再測定してください。
