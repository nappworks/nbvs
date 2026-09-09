# SBV / QV パフォーマンス比較

2026-09-09 に、SBV/QVの補助構造統一とQV hot path最適化後の結果を再測定しました。
以下の結果は `build_cold` / `build_rebuild` を分離し、単体primitive比較と
意味等価な4値Wavelet Matrix比較を含む現行schemaによるものです。

## 測定条件

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
- 分布: `uniform` / `sparse` / `dense` / `skewed`

## 比較の種類

現行ベンチマークは、目的の異なる2種類の比較を同時に出力します。

### primitive

SBV 1個とQV 1個の単体primitive costを比較します。

- QV: 4値symbolをそのまま2-bitで格納
- SBV: 同じ4値symbolの下位1 bitだけを格納

この比較は `access` / `rank` / `select` の1 primitiveあたりのコストを見るためのものです。
SBVとQVで問い合わせの意味が同一ではないため、Quad Wavelet Matrixの優劣を直接判断する
比較には使いません。

### wavelet4

4値alphabetに対して、同じ入力・同じqueryを次の2構造で比較します。

- `BinaryWM2`: Binary Wavelet Matrix 2 level相当。2個のSBVを使用
- `QuadWM1`: Quad Wavelet Matrix 1 level相当。1個のQVを使用

`BinaryWM2` の2 level目SBVは、1 level目のhigh bitによるstable partition後の順序で
low bitを格納します。`access` / `rank(symbol, pos)` / `select(symbol, k)` は双方とも
同じ4値symbolに対する同一意味のqueryです。

この `wavelet4` の比較を、Binary WM 2 level と Quad WM 1 level の実質的な性能比較として
扱います。

## buildの測定

buildは次の2種類を分離して記録します。

- `build_cold`: constructor直後相当のfresh metadataから初回 `build()` を実行
- `build_rebuild`: 一度build済みの構造に対して、既存metadata storageを再利用して再build

`build_cold` ではpayload生成・入力データの充填自体は測定範囲から除外しますが、
初回 `build()` 内で発生するmetadata生成・select sample確保は測定対象です。
これにより、以前のベンチでwarmupに隠れていたQV `selectSamples` の初回確保コストも
明示的に測定できます。

## 実行方法

```sh
nimble benchSbvQv
nimble benchSbvQvSimd
```

実装は [`benchmarks/sbv_quad_vector_comparison.nim`](../sbv_quad_vector_comparison.nim)、
生結果は [scalar CSV](sbv_quad_vector_scalar.csv) と
[SIMD CSV](sbv_quad_vector_simd.csv) に保存します。

## 出力schema

主な列は以下です。

- `comparison`: `primitive` / `wavelet4`
- `structure`: `SBV1` / `QV1` / `BinaryWM2` / `QuadWM1`
- `rank_only_aux_bytes`: rank専用補助領域
- `select_only_aux_bytes`: select専用補助領域
- `shared_aux_bytes`: rank/select共用補助領域
- `total_aux_bytes`: 補助領域合計
- `build_cold_p50_ms`: 初回build
- `build_rebuild_p50_ms`: metadata再利用時のrebuild
- `access_p50_ns`
- `rank_p50_ns`
- `select_p50_ns`

SBVはscalar/SIMDとも旧 `wordPairPrefix` / `blockPairPrefix` を自動生成せず、
階層 `selectStorage` をrank/selectで共用します。そのため現行実装では
`rank_only_aux_bytes == 0`、`shared_aux_bytes == selectStorage` です。

QVはrank metadataとselect sampleを別々に保持するため、
`rank_only_aux_bytes` と `select_only_aux_bytes` に分けて記録します。

## 測定結果

16,777,216 symbolsでの意味等価な `wavelet4` 比較を示します。値は各100,000 queryの
p50で、低いほど高速です。

### scalar

| distribution | structure | build cold (ms) | access (ns) | rank (ns) | select (ns) |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform | BinaryWM2 | 2.441 | 100.656 | 163.264 | 400.958 |
| uniform | QuadWM1 | 7.895 | 16.012 | 105.728 | 192.754 |
| sparse | BinaryWM2 | 2.453 | 83.170 | 159.055 | 386.195 |
| sparse | QuadWM1 | 7.289 | 8.960 | 110.255 | 243.913 |
| dense | BinaryWM2 | 2.150 | 104.356 | 178.233 | 419.002 |
| dense | QuadWM1 | 7.746 | 15.813 | 92.501 | 231.392 |
| skewed | BinaryWM2 | 2.449 | 97.575 | 170.725 | 404.416 |
| skewed | QuadWM1 | 8.186 | 16.471 | 116.943 | 221.846 |

### AVX2/BMI2

| distribution | structure | build cold (ms) | access (ns) | rank (ns) | select (ns) |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform | BinaryWM2 | 1.314 | 65.728 | 127.734 | 236.891 |
| uniform | QuadWM1 | 2.972 | 13.133 | 56.566 | 152.865 |
| sparse | BinaryWM2 | 1.345 | 76.199 | 117.647 | 261.512 |
| sparse | QuadWM1 | 2.809 | 9.512 | 80.956 | 200.682 |
| dense | BinaryWM2 | 1.196 | 97.050 | 127.921 | 295.293 |
| dense | QuadWM1 | 2.763 | 9.340 | 60.811 | 204.318 |
| skewed | BinaryWM2 | 1.204 | 58.501 | 118.056 | 279.262 |
| skewed | QuadWM1 | 2.868 | 5.397 | 66.745 | 185.181 |

`QuadWM1` は `BinaryWM2` に対し、scalar/SIMDの全分布でaccess・rank・selectが高速でした。
一方、cold buildは `BinaryWM2` の方が高速です。全サイズ・primitive比較・rebuild・throughputを
含む値はCSVを参照してください。

## 容量

16,777,216 symbolsのQV payloadは4,194,304 bytes、rank補助は262,144 bytes
（6.25%）でした。select補助は分布により65,536–65,560 bytesで、合計補助容量は
327,680–327,704 bytes（約7.8125%）です。

現行測定では、16,777,216 symbolsのSBV 1個の共用 `selectStorage` は
scalar/SIMDとも74,912 bytesです。`rank_only_aux_bytes` は両backendとも0で、
SIMD専用だった `blockPairPrefix` は保持しません。

## 注意事項

WSL2上の単一ホストでの測定です。特に65,536 symbolsのbuildは測定時間が短いため、
絶対値や数%の差を評価する用途では試行回数または反復build回数を増やして
再測定してください。
