# PR #21 固定depth traversal ベンチマーク

測定日: 2026-09-21  
対象コミット: `d55dda7`（測定後にコンパイル修正を追加）

## 測定条件

- Nim 2.2.10、Linux amd64 / WSL2、release、ARC
- CPU: Intel Core i5-8365U、8 logical CPUs、AVX2/BMI2
- scalar はデフォルト実装、SIMD は `-d:nbvsSimd`
- A/B 実装を同一process・同一入力で交互に測定
- value enumeration と QWM はウォームアップ1回＋測定7回の中央値
- speedup は `legacy_ns / fixed_depth_ns` または `legacy_ns / current_ns`。1.0超が改善

ベンチマークコマンド:

```text
nim c --path:src -d:release --mm:arc -r benchmarks/wm_value_enumeration_depth_ab.nim
nim c --path:src -d:release --mm:arc -d:nbvsSimd -r benchmarks/wm_value_enumeration_depth_ab.nim
nim c --path:src -d:release --mm:arc -r benchmarks/wm_rwm_fixed_depth_query_ab.nim
nim c --path:src -d:release --mm:arc -d:nbvsSimd -r benchmarks/wm_rwm_fixed_depth_query_ab.nim
nim c --path:src -d:release --mm:arc -r benchmarks/qwm_pair_enumeration_ab.nim
nim c --path:src -d:release --mm:arc -d:nbvsSimd -r benchmarks/qwm_pair_enumeration_ab.nim
```

## 結果概要

| 対象 | backend | ケース数 | speedup 平均 | 最小 | 最大 | 改善/同等 | 回帰 |
|:---|:---|---:|---:|---:|---:|---:|---:|
| WM/RWM value enumeration | scalar | 20 | 1.1797 | 1.0074 | 1.3310 | 20 | 0 |
| WM/RWM value enumeration | SIMD | 20 | 1.4044 | 1.2068 | 1.7619 | 20 | 0 |
| WM/RWM core queries | scalar | 10 | 1.0699 | 0.9740 | 1.1455 | 9 | 1 |
| WM/RWM core queries | SIMD | 10 | 1.1019 | 0.9820 | 1.1698 | 8 | 2 |
| QWM pair/all-rank traversal | scalar | 28 | 1.3392 | 0.8783 | 2.5318 | 18 | 10 |
| QWM pair/all-rank traversal | SIMD | 28 | 1.1684 | 0.7125 | 2.0886 | 20 | 8 |

WM/RWM value enumeration は scalar・SIMDとも全ケースで改善しました。WM/RWM core query は
大部分が改善し、scalar の `rwm_access` (0.9740)、SIMD の `wm_count_less_than` (0.9965)
と `rwm_access` (0.9820) に小さな回帰がありました。

QWM は `quantile` と `full_value_counts` / `range_value_counts` で大きく改善しました。
一方、特に SIMD の高cardinality条件では `count_less_than` (0.7125)、`rank_pair` (0.8118)、
`select` (0.8784) などの回帰があり、今回の結果だけでは全クエリへの一律適用を性能面で
保証できません。全ケースの生データは以下に保存しています。

- [WM/RWM value enumeration scalar](wm_value_enumeration_depth_ab_scalar.csv)
- [WM/RWM value enumeration SIMD](wm_value_enumeration_depth_ab_simd.csv)
- [WM/RWM core queries scalar](wm_rwm_fixed_depth_query_ab_scalar.csv)
- [WM/RWM core queries SIMD](wm_rwm_fixed_depth_query_ab_simd.csv)
- [QWM pair/all-rank scalar](qwm_pair_enumeration_ab_scalar.csv)
- [QWM pair/all-rank SIMD](qwm_pair_enumeration_ab_simd.csv)

## Guardrail 結果

既存の WM fixed-depth A/B と WM/QWM end-to-end も同じ環境で再測定しました。

| 対象 | backend | ケース数 | speedup 平均 | 最小 | 最大 | 改善/同等 | 回帰 |
|:---|:---|---:|---:|---:|---:|---:|---:|
| WM fixed-depth A/B | scalar | 24 | 1.0255 | 0.8873 | 1.1368 | 15 | 9 |
| WM fixed-depth A/B | SIMD | 24 | 1.0874 | 0.9522 | 1.3215 | 20 | 4 |

WM/QWM end-to-end は 65,536〜16,777,216 rows、8〜64 bit幅、uniform/skewed の全ケースを
完走しました。QWMは多くの access/rank/select でWMより速くなりましたが、auxiliary metadata
容量は増加します。17M rows/64 bitではWM 139,012,096 bytesに対してQWM 144,703,640 bytes
です。絶対値はCPU負荷の影響を受けるため、全行を生CSVに保存しています。

- [WM fixed-depth guardrail scalar](pr21_wm_fixed_depth_guardrail_scalar.csv)
- [WM fixed-depth guardrail SIMD](pr21_wm_fixed_depth_guardrail_simd.csv)
- [WM/QWM end-to-end guardrail scalar](pr21_wm_qwm_guardrail_scalar.csv)
- [WM/QWM end-to-end guardrail SIMD](pr21_wm_qwm_guardrail_simd.csv)

## 再現性

CPU frequency、CPU affinity、WSL2のホスト負荷は固定していません。したがって、表の値は
この環境での比較用結果であり、別環境での絶対値を保証しません。SIMD測定はCPUのAVX2/BMI2
サポートを確認して実行しました。
