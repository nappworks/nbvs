# nbvs ベンチマーク

## 概要

現在の実装について、デフォルトのportable scalar backendと
`-d:nbvsSimd` で有効化するAVX2/BMI2 backendを比較した結果です。
2026-07-17の安定測定を基準表として保持し、2026-08-02のbuild最適化比較と
今後の改善方針を併記しています。

以下の2026-07-17既存性能表は、ウォームアップを1回実行した後の3試行の中央値です。
生の計測結果は `benchmarks/*_trial[1-3].csv` に保存しています。

## FmDictionary query／構築メモリ改善（2026-08-05）

`nbvs_fmDirectory_add2.md`と`nbvs_fmDirectory_add3.md`に基づき、次を採用しました。

- LF traversalを`accessRank` 1回の`lfStep`へ融合
- exact／prefixを開始separatorを含むanchored searchへ変更
- patternの`seq[FmSymbol]` allocationを除去
- `rankPair`でbackward stepの左右rankを融合
- `FmQueryWorkspace`でsubstringのsort対象をoccurrence数からunique ID数へ削減
- `findPrefixInto`、`findSubstringInto`、`getStringInto`で出力bufferを再利用
- `startsAt`／`endsAt`をseparator位置`SuccinctBitVector`へ置換
- `uint64` BWT展開を廃止し、`uint16` BWTからWavelet Matrixを直接構築
- SA-ISのbucketを`uint32`化し、初回／最終induced sortでSA bufferを再利用

query値は10,000回のwarm queryです。candidateのprefix、substring、restoreは
workspace／出力bufferを再利用する`Into` APIを測定しています。CPU affinityを固定して
いないため、特に小規模ケースの絶対値には実行時の揺れがあります。

### 100万件・平均16 byteの更新前後比較

同一のrelease/ARCバイナリを同じセッションで実行し、`/proc/<pid>/status`の`VmRSS`を
10ms間隔で取得しました。query用入力も含むプロセス全体のpeak RSSです。

| metric | baseline | candidate | 変化 |
|:---|---:|---:|---:|
| peak RSS | 1,383,020 KiB | 683,656 KiB | -50.6% |
| 完成後storage | 24.801 MiB | 24.801 MiB | 変更なし |
| FM build | 5,546.307 ms | 5,679.604 ms | +2.4% |
| exact | 45,247.6 ns | 34,804.5 ns | -23.1% |
| prefix | 44,830.3 ns | 35,561.7 ns | -20.7% |
| substring | 41,838.2 ns | 34,126.8 ns | -18.4% |
| restore | 39,759.6 ns | 34,989.4 ns | -12.0% |

ピークRSSは目標の30%削減を上回り、構築時間の増加は3%未満でした。完成後の
保持形式は変更していません。`validateDistinct: false`の効果は入力保証がある用途向けで、
上表は後方互換な既定値`true`で測定しています。

### Candidate query latency

| strings | avg bytes | exact ns | prefix into ns | substring into ns | restore into ns |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 8 | 7,264.1 | 6,866.9 | 6,898.2 | 8,816.3 |
| 10,000 | 16 | 17,920.0 | 17,049.3 | 15,870.3 | 15,007.4 |
| 10,000 | 32 | 30,978.0 | 31,019.0 | 38,406.1 | 25,317.2 |
| 10,000 | 16（日本語） | 20,500.7 | 17,416.3 | 17,717.1 | 18,020.3 |
| 100,000 | 16 | 22,213.1 | 20,274.9 | 19,757.5 | 20,170.1 |
| 1,000,000 | 16 | 31,729.4 | 29,634.0 | 28,816.5 | 29,637.2 |

最終行は全ケース連続測定時の値です。上のbaseline比較表はpeak RSS測定セッションの値を
使用しているため、CPU schedulerの影響で絶対値が異なります。

### Fused primitive比較

| strings | rank × 2 ns | rankPair ns | rankPair速度倍率 |
|---:|---:|---:|---:|
| 10,000（16 byte） | 857.8 | 755.2 | 1.14x |
| 1,000,000（16 byte） | 1,090.0 | 694.8 | 1.57x |

`rankPair`は両規模で改善を確認できたため、FmDictionaryの`backwardStep`へ採用しました。
PackedArray BWTは、`uint16`直接入力だけで50%以上のpeak RSS削減を達成し、packed展開の
構築時間リスクを追加する必要がないため採用していません。LF samplingも完成後storageを
増やすため、今回の「完成後メモリを維持する」範囲では採用していません。

## FmDictionary（2026-08-05）

以下は改善前の基準値です。`benchmarks/fm_dictionary_bench.nim`で、固定seedから
生成したdistinct文字列をrelease/ARC構成で測定しました。queryは10,000回で、prefixとsubstringには
選択性を一定にするため登録文字列全体をpatternとして使用しています。結果件数の多い
検索は、SA interval幅と返却ID数に比例する追加コストが発生します。

実行環境は Intel Core i5-8365U（4 cores / 8 threads）、WSL2 Linux x86_64、
Nim 2.2.10、GCC 15.2.0です。CPU affinityは固定していないため、絶対値ではなく
同一実行内の比較を主目的とします。

```bash
nim c --path:src -d:release --mm:arc \
  --out:/tmp/nbvs_fm_bench benchmarks/fm_dictionary_bench.nim
/tmp/nbvs_fm_bench 10000 8
/tmp/nbvs_fm_bench 10000 16
/tmp/nbvs_fm_bench 10000 32
/tmp/nbvs_fm_bench 10000 16 ja
/tmp/nbvs_fm_bench 100000 16
/tmp/nbvs_fm_bench 1000000 16
```

### 構築と保持メモリ

`SA`、`BWT`、`WM`は各段階を単独で測定し、`FM build`は入力から完成した
`FmDictionary`までの時間です。`bytes/char`は完成後の主要な保持bufferのみを
元文字列の総byte数で割った値で、構築時のSuffix Arrayと作業配列は含みません。

| strings | avg bytes | data | symbols | SA ms | BWT ms | WM ms | FM build ms | storage MiB | bytes/char |
|---:|---:|:---|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 8 | ASCII | 90,002 | 7.945 | 0.401 | 3.381 | 14.585 | 0.141 | 1.842 |
| 10,000 | 16 | ASCII | 170,002 | 13.706 | 0.713 | 6.394 | 26.378 | 0.235 | 1.542 |
| 10,000 | 32 | ASCII | 330,002 | 24.311 | 1.435 | 12.022 | 51.774 | 0.424 | 1.388 |
| 10,000 | 16 | UTF-8日本語 | 171,892 | 16.474 | 0.778 | 6.922 | 30.898 | 0.237 | 1.535 |
| 100,000 | 16 | ASCII | 1,700,002 | 159.512 | 11.224 | 70.716 | 292.099 | 2.410 | 1.579 |
| 1,000,000 | 16 | ASCII | 17,000,002 | 2,499.890 | 167.868 | 996.087 | 4,480.665 | 24.801 | 1.625 |

SA-ISは入力の`uint16` symbol列を変換せず、L/S型とLMS位置を2つの`BitVector`に
保持します。分類flagの論理容量は
合計`n/4` byteで、旧prefix-doubling実装の2本の`seq[int64]`（概ね`16n` byte）
より小さくなります。SA本体、縮約列、bucket配列は別途必要です。

旧prefix-doubling基準との同一データ・同一ビルド条件での比較は次のとおりです。

| strings | avg bytes | 旧SA ms | SA-IS ms | SA速度倍率 | 旧FM build ms | SA-IS FM build ms | 全体速度倍率 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 8 | 32.539 | 7.945 | 4.10x | 37.807 | 14.585 | 2.59x |
| 10,000 | 16 | 81.924 | 13.706 | 5.98x | 95.403 | 26.378 | 3.62x |
| 10,000 | 32 | 273.905 | 24.311 | 11.27x | 236.143 | 51.774 | 4.56x |
| 10,000 | 16（日本語） | 77.917 | 16.474 | 4.73x | 90.137 | 30.898 | 2.92x |
| 100,000 | 16 | 1,671.215 | 159.512 | 10.48x | 1,650.547 | 292.099 | 5.65x |
| 1,000,000 | 16 | 20,341.959 | 2,499.890 | 8.14x | 24,812.409 | 4,480.665 | 5.54x |

### Query latency

| strings | avg bytes | FM exact ns | sorted binary exact ns | prefix ns | substring ns | restore ns |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 8 | 7,688.1 | 395.4 | 6,540.5 | 7,009.1 | 8,219.9 |
| 10,000 | 16 | 13,800.6 | 386.9 | 14,362.0 | 13,109.5 | 13,483.6 |
| 10,000 | 32 | 26,262.5 | 446.3 | 24,544.6 | 23,695.8 | 24,349.1 |
| 10,000 | 16（日本語） | 14,627.0 | 248.4 | 13,436.0 | 14,659.0 | 18,327.4 |
| 100,000 | 16 | 18,055.3 | 802.2 | 17,700.9 | 18,634.3 | 18,429.3 |
| 1,000,000 | 16 | 41,243.4 | 3,524.2 | 38,956.3 | 38,570.9 | 42,571.3 |

元文字列を保持するsorted binary searchはexact lookupのみを提供するため高速ですが、
self-indexではなく、suffix・substring検索やIDからの自己復元は提供しません。

### Hot path microbenchmark

| strings | access + rank ns | accessRank ns | 速度倍率 | PackedArray checked ns | getUnchecked ns |
|---:|---:|---:|---:|---:|---:|
| 10,000（8 byte） | 651.4 | 379.0 | 1.72x | 17.2 | 18.5 |
| 10,000（16 byte） | 597.5 | 343.6 | 1.74x | 17.0 | 15.6 |
| 10,000（32 byte） | 650.5 | 397.5 | 1.64x | 26.9 | 21.3 |
| 100,000（16 byte） | 670.7 | 408.3 | 1.64x | 20.5 | 17.7 |
| 1,000,000（16 byte） | 1,212.3 | 1,137.5 | 1.07x | 32.9 | 29.1 |

融合した`accessRank`はLF-mapping相当のWavelet Matrix走査を1.07〜1.74倍高速化
しました。`cTable.getUnchecked`の効果は小さいものの、大規模ケースではchecked access
より約12%短縮しました。unchecked版はFmDictionary内部でsymbol範囲を保証できる
hot pathだけに使用しています。

## 現在地

この文書の既存性能表は、2026-07-17に取得したbackend比較の基準値です。
その後、2026-08-02に実行経路最適化を検証し、`SuccinctBitVector.build()` の
select tree初期化を全領域から末尾paddingだけへ限定する変更を採用しました。

現時点の要点は次のとおりです。

- Scalar/SIMD固有のrank補助構造とselect treeの論理形式は維持しています。
- 保持メモリ、object metadata、seq数、公開API、query経路は変わりません。
- 直接SBV benchmarkでは、build時間がScalarで約15.8%〜45.2%、
  SIMDで約30.4%〜53.8%短縮しました。
- Rank pair、access-rank融合、強制inlineは主要queryの非劣化条件を満たさず、
  製品コードから撤回済みです。
- `-march=native` は一部で有効でしたが、portable性を失うため標準設定にはしません。
- Scalar/SIMDの全テスト、WM、RWM、Elias–Fanoの回帰テスト、APIドキュメント生成、
  保持メモリ測定は成功しています。

### 最新のbuild比較

同じNim、GCC、WSL2セッションでbaselineとpadding限定初期化を比較した値です。
`build()` は各ケース20回実行し、表の値は1回あたりの時間です。
checksumはScalar/SIMDともに `41678230` で一致しています。

#### Scalar (`-d:release --mm:arc`)

| bits | density | baseline_ms | current_ms | 短縮率 | 速度倍率 |
|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 50% | 0.221772 | 0.121524 | 45.2% | 1.82x |
| 16,777,216 | 50% | 2.810420 | 1.647173 | 41.4% | 1.71x |
| 67,108,864 | 50% | 11.624118 | 7.124438 | 38.7% | 1.63x |
| 16,777,216 | 1% | 2.340292 | 1.655633 | 29.3% | 1.41x |
| 16,777,216 | 99% | 2.412990 | 2.032030 | 15.8% | 1.19x |

#### AVX2/BMI2 (`-d:release --mm:arc -d:nbvsSimd`)

| bits | density | baseline_ms | current_ms | 短縮率 | 速度倍率 |
|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 50% | 0.059132 | 0.041135 | 30.4% | 1.44x |
| 16,777,216 | 50% | 1.279299 | 0.790995 | 38.2% | 1.62x |
| 67,108,864 | 50% | 7.429617 | 3.431058 | 53.8% | 2.17x |
| 16,777,216 | 1% | 1.192165 | 0.776830 | 34.8% | 1.53x |
| 16,777,216 | 99% | 1.282649 | 0.858196 | 33.1% | 1.49x |

この最新比較は最適化候補の採否判断用の単一セッション測定です。下記の既存性能表のような
ウォームアップ後3試行中央値へまだ統合していないため、queryの新しい基準値としては扱いません。
詳細な生値と判断理由は `benchmarks/results/build_fusion_*.json` および
`benchmarks/results/execution_path_comparison.md` に保存しています。

## 実行環境

- 計測日: 2026-07-17
- CPU: Intel Core i5-8365U
- CPU構成: 4 cores / 8 threads
- CPU flags: AVX2、BMI2、POPCNT対応
- OS: Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- Nim: 2.2.10
- C compiler: GCC 15.2.0
- Memory management: ORC
- ビルド: `-d:release`
- CPU affinity: CPU 0へ固定

WSL2上の計測値であり、ホスト側の負荷や電力管理の影響を受けるため、
絶対値ではなく同一条件におけるbackend間の比較を主目的とします。

## ビルドと計測方法

scalar binaryは追加defineなし、SIMD binaryは `-d:nbvsSimd` を指定して
ビルドしました。

```bash
nim c -d:release --path:src \
  --out:/tmp/nbvs-sbv_perf-scalar benchmarks/sbv_perf.nim
nim c -d:release -d:nbvsSimd --path:src \
  --out:/tmp/nbvs-sbv_perf-simd benchmarks/sbv_perf.nim

taskset -c 0 /tmp/nbvs-sbv_perf-scalar
taskset -c 0 /tmp/nbvs-sbv_perf-simd
```

`ef_perf.nim`、`wm_perf.nim`、`wm_range_rank_perf.nim` も同じ方法で
scalarとSIMDをそれぞれビルドし、CPU 0へ固定して実行しました。

## SuccinctBitVector

`build()` は各ケース20回、queryは各2,000,000回実行しています。
`build_ms` は1回あたり、query列は1 queryあたりの時間です。

### Scalar

| bits | density | MiB | build_ms | rank1_ns | select1_ns | select0_ns |
|---:|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 50% | 0.12 | 0.125690 | 84.506 | 235.161 | 420.767 |
| 16,777,216 | 50% | 2.00 | 4.037588 | 119.694 | 340.264 | 577.493 |
| 67,108,864 | 50% | 8.00 | 19.389518 | 273.010 | 505.985 | 681.086 |
| 16,777,216 | 1% | 2.00 | 4.073362 | 136.421 | 302.813 | 451.065 |
| 16,777,216 | 99% | 2.00 | 2.101049 | 63.942 | 172.868 | 237.361 |

### AVX2/BMI2

| bits | density | MiB | build_ms | rank1_ns | select1_ns | select0_ns |
|---:|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 50% | 0.12 | 0.048682 | 20.489 | 66.406 | 118.963 |
| 16,777,216 | 50% | 2.00 | 1.063203 | 27.933 | 119.352 | 170.839 |
| 67,108,864 | 50% | 8.00 | 4.767236 | 64.773 | 195.198 | 247.673 |
| 16,777,216 | 1% | 2.00 | 1.027621 | 28.790 | 121.072 | 176.745 |
| 16,777,216 | 99% | 2.00 | 1.017027 | 26.810 | 117.949 | 169.964 |

### SIMD速度倍率

倍率は `scalar / SIMD` です。

| bits | density | build | rank1 | select1 | select0 |
|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 50% | 2.58x | 4.12x | 3.54x | 3.54x |
| 16,777,216 | 50% | 3.80x | 4.29x | 2.85x | 3.38x |
| 67,108,864 | 50% | 4.07x | 4.22x | 2.59x | 2.75x |
| 16,777,216 | 1% | 3.96x | 4.74x | 2.50x | 2.55x |
| 16,777,216 | 99% | 2.07x | 2.38x | 1.47x | 1.40x |

## EliasFano

`build()` は各ケース20回、queryは各2,000,000回実行しています。
`storage_mib` は構築後の主要な内部bufferを合計した値です。

### Scalar

| n | universe/value | low bits | storage_mib | build_ms | access_ns | lower_bound_ns | upper_bound_ns | predecessor_ns |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 65,536 | 16 | 4 | 0.047 | 1.254440 | 99.694 | 494.471 | 493.524 | 503.957 |
| 1,048,576 | 2 | 1 | 0.384 | 25.684376 | 129.771 | 596.027 | 589.891 | 596.181 |
| 1,048,576 | 16 | 4 | 0.759 | 19.847172 | 129.596 | 598.285 | 617.046 | 606.023 |
| 1,048,576 | 256 | 8 | 1.259 | 19.793870 | 138.576 | 607.730 | 605.064 | 614.161 |
| 4,194,304 | 16 | 4 | 3.036 | 82.406463 | 199.875 | 709.424 | 704.238 | 710.861 |

### AVX2/BMI2

| n | universe/value | low bits | storage_mib | build_ms | access_ns | lower_bound_ns | upper_bound_ns | predecessor_ns |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 65,536 | 16 | 4 | 0.047 | 1.167200 | 44.855 | 256.152 | 258.219 | 259.069 |
| 1,048,576 | 2 | 1 | 0.384 | 18.620258 | 54.362 | 319.747 | 313.510 | 331.950 |
| 1,048,576 | 16 | 4 | 0.759 | 18.098960 | 61.173 | 337.588 | 334.134 | 325.647 |
| 1,048,576 | 256 | 8 | 1.259 | 19.341724 | 62.383 | 337.991 | 344.668 | 342.838 |
| 4,194,304 | 16 | 4 | 3.067 | 73.909300 | 97.711 | 445.827 | 428.155 | 439.213 |

SIMD backendでは、大きな `SuccinctBitVector` にrank用の補助prefixを追加するため、
最後のケースのstorageがscalarより約0.031 MiB増えています。

## WaveletMatrix / ReversedWaveletMatrix

`build()` は各ケース10回、access・rank・selectは各1,000,000回、
`valueCounts()` は各5回実行しています。値はウォームアップ後3試行の中央値です。

この既存表の `value_counts_ms` は、昇順結果を返す `valueCounts()` 全体の時間です。
現在の `wm_perf.nim` は、sortしない `collect_value_counts_ms` と、収集後に昇順sortする
`sorted_value_counts_ms` を別々に出力します。次回baseline更新時に下表も2列へ更新します。

分離後の単一セッション測定では、1,048,576要素・alphabet 1,048,576の純粋な頻度収集が
次の結果になりました。

| backend | WM collect_ms | RWM collect_ms | WM sorted_ms | RWM sorted_ms |
|:---|---:|---:|---:|---:|
| Scalar | 81.105975 | 81.551693 | 92.751824 | 250.326293 |
| AVX2/BMI2 | 67.727966 | 67.854915 | 81.353847 | 236.718841 |

純粋な収集時間のWM/RWM差は1%未満であり、MSB-first/LSB-firstの走査方向だけでは
大きな性能差が出ないという想定と一致します。従来の差は、RWMの走査結果を数値昇順へ
並べ替える比較sortが主因です。全ケースは
`benchmarks/results/value_counts_split_scalar.csv` と
`benchmarks/results/value_counts_split_simd.csv` に保存しています。

### Scalar

| kind | n | alphabet | bits | storage_mib | build_ms | access_ns | rank_ns | select_ns | value_counts_ms |
|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| WM | 65,536 | 256 | 8 | 0.069 | 4.288816 | 307.647 | 442.708 | 1,340.180 | 0.014201 |
| RWM | 65,536 | 256 | 8 | 0.069 | 3.730043 | 306.983 | 430.182 | 1,424.139 | 0.030521 |
| WM | 1,048,576 | 256 | 8 | 1.098 | 71.995853 | 423.780 | 564.290 | 1,855.396 | 0.017781 |
| RWM | 1,048,576 | 256 | 8 | 1.098 | 64.847096 | 404.778 | 569.559 | 1,855.033 | 0.034062 |
| WM | 1,048,576 | 1,048,576 | 20 | 2.746 | 175.136236 | 1,405.930 | 1,785.839 | 5,371.736 | 78.698678 |
| RWM | 1,048,576 | 1,048,576 | 20 | 2.746 | 159.173771 | 1,312.840 | 1,774.377 | 5,346.857 | 256.397886 |
| WM | 4,194,304 | 256 | 8 | 4.393 | 299.946073 | 657.295 | 805.862 | 2,264.847 | 0.019061 |
| RWM | 4,194,304 | 256 | 8 | 4.393 | 259.937055 | 662.579 | 796.394 | 2,237.559 | 0.039822 |

### AVX2/BMI2

| kind | n | alphabet | bits | storage_mib | build_ms | access_ns | rank_ns | select_ns | value_counts_ms |
|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| WM | 65,536 | 256 | 8 | 0.065 | 4.040294 | 280.397 | 379.708 | 822.588 | 0.014721 |
| RWM | 65,536 | 256 | 8 | 0.065 | 3.803889 | 334.320 | 409.100 | 829.497 | 0.040542 |
| WM | 1,048,576 | 256 | 8 | 1.036 | 83.692241 | 431.142 | 579.286 | 1,471.561 | 0.015461 |
| RWM | 1,048,576 | 256 | 8 | 1.036 | 66.422115 | 371.231 | 476.172 | 1,350.044 | 0.031982 |
| WM | 1,048,576 | 1,048,576 | 20 | 2.590 | 182.950391 | 1,190.274 | 1,679.121 | 4,057.962 | 74.973385 |
| RWM | 1,048,576 | 1,048,576 | 20 | 2.590 | 171.148428 | 1,216.398 | 1,605.213 | 4,293.440 | 257.012298 |
| WM | 4,194,304 | 256 | 8 | 4.143 | 303.973731 | 593.737 | 664.630 | 1,773.260 | 0.015842 |
| RWM | 4,194,304 | 256 | 8 | 4.143 | 256.693712 | 615.705 | 687.502 | 1,848.968 | 0.032899 |

## PackedArray

要素数1,048,576の配列について、`fill` は10回、`toSeq` は5回、
逐次 `set` は3回、ランダム `get` は2,000,000回実行しています。
値はウォームアップ後3試行の中央値です。

| bits | storage_mib | fill_ms | to_seq_ms | sequential_set_ns | random_get_ns |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.125 | 0.003440 | 3.887381 | 8.443 | 7.721 |
| 3 | 0.375 | 0.010090 | 4.303916 | 8.705 | 9.355 |
| 7 | 0.875 | 0.039271 | 3.914362 | 8.966 | 9.967 |
| 8 | 1.000 | 0.038901 | 3.711955 | 8.571 | 8.760 |
| 13 | 1.625 | 0.076343 | 4.300856 | 8.803 | 11.582 |
| 16 | 2.000 | 0.075583 | 4.081068 | 9.603 | 17.523 |
| 31 | 3.875 | 0.357833 | 4.436541 | 9.814 | 21.780 |
| 32 | 4.000 | 0.185327 | 4.455502 | 9.058 | 22.096 |
| 63 | 7.875 | 0.320552 | 5.504620 | 10.285 | 36.917 |
| 64 | 8.000 | 0.509989 | 1.419512 | 5.404 | 26.088 |

## Range rank

直接rangeを処理する `rank(value, left, right)` と、2回のprefix rankの差を
取る方法を各1,000,000回比較しています。値は1 queryあたりのnsです。

### Scalar

| n | alphabet | bits | WM direct | WM two-prefix | RWM direct | RWM two-prefix |
|---:|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 256 | 8 | 642.173 | 1,158.670 | 655.646 | 1,118.753 |
| 1,048,576 | 1,048,576 | 20 | 1,891.757 | 3,336.400 | 1,881.348 | 3,485.250 |

### AVX2/BMI2

| n | alphabet | bits | WM direct | WM two-prefix | RWM direct | RWM two-prefix |
|---:|---:|---:|---:|---:|---:|---:|
| 1,048,576 | 256 | 8 | 505.910 | 965.078 | 511.106 | 931.626 |
| 1,048,576 | 1,048,576 | 20 | 1,508.187 | 2,890.424 | 1,505.823 | 2,806.012 |

すべてのケースで、直接rangeを処理するAPIが2回のprefix rankより高速でした。

## 生データ

各suite・backendについて3試行を保存しています。

- `sbv_scalar_trial[1-3].csv`
- `sbv_simd_trial[1-3].csv`
- `ef_scalar_trial[1-3].csv`
- `ef_simd_trial[1-3].csv`
- `wm_scalar_trial[1-3].csv`
- `wm_simd_trial[1-3].csv`
- `wm_range_rank_scalar_trial[1-3].csv`
- `wm_range_rank_simd_trial[1-3].csv`
- `packed_array_trial[1-3].csv`

## 検証済み候補と判断

| 候補 | 判断 | 主な結果 |
|:---|:---|:---|
| select treeのpadding限定初期化 | 適用 | SBV buildをScalar 15.8%〜45.2%、SIMD 30.4%〜53.8%短縮 |
| `rank1PairUnchecked` | 見送り | Scalarの一部だけ改善し、8-bit WM、RWM、SIMDで悪化 |
| accessとrankのtuple融合 | 見送り | rank内部のword loadを共有できず、追加境界の固定費を回収できない |
| rank prefix/helperの強制inline | 見送り | compile timeが約2.5倍になり、代表range rankも悪化 |
| storage field統合 | 見送り | hot pathのindex計算増加が見込まれ、現行構造維持の利点がない |
| GCC `-march=native` | benchmark限定 | 一部改善するが、生成binaryのCPU互換性を失う |
| GCC LTO | 見送り | 代表ケースで一貫した改善がなく、selectは悪化 |
| ORCへの切替 | 見送り | 代表ケースではARCより一貫して高速にならなかった |

Rank pairの試作値、inline比較、compiler option比較はそれぞれ
`benchmarks/results/query_fusion_rank_pair_*.json`、
`benchmarks/results/inline_comparison.json`、
`benchmarks/results/compiler_comparison.json` を参照してください。

## 今後の改善方針

### 優先度1: 現行baselineの更新と測定安定化

今回採用したbuild最適化を含むcommitを基準として、既存の全suiteを再測定します。

- warm-upを最低3回、本測定を最低10回実行する
- baselineとcandidateを同一セッションで交互に測定する
- 中央値に加えて平均、最小、最大、標準偏差を保存する
- 可能ならCPU affinityを固定し、WSL2のホスト負荷を記録する
- Scalar/SIMD、ARC/ORCでchecksumを比較する

これにより、この文書の2026-07-17表を現在の実装へ更新し、単発測定と長期baselineを
混同しない状態にします。

### 優先度2: Wavelet Matrix buildのprofile取得

SBV単体buildは改善しましたが、WM/RWM build全体には値のstable partitionやlevelごとの
一時buffer走査も含まれます。次は推測で融合せず、以下を分離計測します。

- level bit生成
- `SuccinctBitVector.build()`
- zero/one stable partition
- `current` / `next` bufferの初期化とswap
- Scalar/SIMDごとのpopcount時間

保持構造やquery性能を変えず、走査・書込み・一時allocationを減らせる場合だけ採用します。

### 優先度3: query hot pathの生成コード調査

単純なRank Pairと強制inlineは見送りました。再度query融合を試す場合は、先に生成Cまたは
assemblyでraw word load、prefix load、関数境界が実際に残っている箇所を確認します。

- `countLessThan`、`quantile`、range rankを個別にprofileする
- 同一512-bit blockの比率を入力分布別に記録する
- helper単体ではなくWM/RWM全体で3%以上改善する場合だけ採用する
- Scalar/SIMDのいずれかで1%以上悪化する変更は原則として撤回する

### 優先度4: benchmark専用compiler設定

`-march=native` はローカル測定用として継続評価できます。library既定値はportableな
GCC release + ARCを維持します。Clangは現在の環境に未導入のため、導入可能な環境で
GCCとの同条件比較を追加します。

### 継続して確認する回帰項目

- WM/RWMのbuild、access、rank、select、collectValueCounts、valueCounts
- Elias–Fanoのbuild、access、lowerBound、upperBound、predecessor
- Scalar/SIMDの保持メモリとchecksum
- binary size、compile time、peak RSS
- 空、全0、全1、疎、密、512-bit境界、再build

## 当面再検討しない領域

過去の測定でbackend間の性能を同時に維持できなかったため、明確な新しい根拠がない限り
以下は優先しません。

- Scalar/SIMDのprefix形式完全統一
- prefix間隔やpacked prefix形式の再設計
- query専用sampling indexや恒常的cacheの追加
- Select treeの全面置換
- storage field統合だけを目的としたデータ配置変更

現時点では、保持メモリを増やさず、上位build処理の測定可能な走査削減を進めることが
最もリスクと効果の釣り合う方向です。

## Select実行経路最適化（2026-08-03）

16,777,216 bits、50%密度、2,000,000 random queryを、baseline/candidateの実行順を
交互にして10回測定しました。最終変更はSIMD `select0` だけに作用します。

| backend | API | baseline中央値 | candidate中央値 | 結果 |
|:---|:---|---:|---:|:---|
| Scalar | select1 | 136.339 ns | 同一経路 | 変更なし |
| Scalar | select0 | 213.793 ns | 同一経路 | 変更なし |
| AVX2/BMI2 | select1 | 109.848 ns | 110.662 ns | 0.7%差 |
| AVX2/BMI2 | select0 | 154.234 ns | 111.704 ns | 27.6%改善 |

採用した変更は、各levelのvalid child計算を整数除算からfull-node fast pathとshiftへ変更すること、
zero offset vectorをlevelごとにstatic選択すること、valid lane mask helperだけをinline化することです。
保持メモリと公開APIは変わりません。

AVX2 leaf popcountはScalar POPCNTより遅く、Scalar early breakもbranch predictionにより悪化したため
見送りました。PDEPとTZCNTは既に各1命令へ展開されています。詳細は
`benchmarks/results/select_optimization_comparison.md` を参照してください。
