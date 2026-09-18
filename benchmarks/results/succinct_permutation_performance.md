# SuccinctPermutation performance

PR #20の `SuccinctPermutation` について、完全なinverse permutationをもう1本の
`PackedArray`として保持する基準実装と比較しました。測定対象はcommit
`f2677de4efa5276735162166a546145f929957f5`にベンチマーク追加だけを加えた作業ツリーです。

## 測定条件

- Intel Core i5-8365U、4 cores / 8 threads、AVX2/BMI2対応
- Linux 5.15.146.1-microsoft-standard-WSL2 x86_64
- Nim 2.2.10、GCC 15.2.0、C backend、ARC、release build
- 65,536 / 1,048,576要素、inverse stride 8 / 32 / 128
- 固定seedのFisher-Yates順から作成した、全nodeを含む単一の長いcycle
- 各operationは固定seedの200,000 query、warmup 1回、測定7回のp50
- 実行順はbuild、forward、inverseの順で、CPU周波数は固定していません

基準実装もforward/inverseの双方を同じbit幅の`PackedArray`で保持します。
したがって、非圧縮な`seq[uint64]`との比較ではなく、完全inverseを保持する場合との
格納方式の差を測っています。容量は各構造が所有するpayloadとrank/select metadataの
論理byte数であり、object/seq headerとallocator overheadは含みません。

## 実行方法

```sh
nimble benchSuccinctPermutation
nimble benchSuccinctPermutationSimd
```

生結果は[scalar CSV](succinct_permutation_scalar.csv)と
[SIMD CSV](succinct_permutation_simd.csv)、環境情報は
[environment](succinct_permutation_environment.txt)に保存しています。

## 1,048,576要素の結果

| backend | stride | landmarks | succinct bytes | packed pair bytes | memory ratio | build p50 (ms) | access (ns/query) | inverse (ns/query) | inverse slowdown |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 8 | 131,072 | 3,084,896 | 5,242,880 | 0.588 | 217.845 | 28.419 | 1,172.044 | 37.407x |
| scalar | 32 | 32,768 | 2,839,136 | 5,242,880 | 0.542 | 205.139 | 34.415 | 3,633.748 | 109.866x |
| scalar | 128 | 8,192 | 2,777,696 | 5,242,880 | 0.530 | 202.016 | 28.800 | 13,589.078 | 489.610x |
| AVX2/BMI2 | 8 | 131,072 | 3,084,896 | 5,242,880 | 0.588 | 224.983 | 30.210 | 1,067.579 | 38.759x |
| AVX2/BMI2 | 32 | 32,768 | 2,839,136 | 5,242,880 | 0.542 | 214.099 | 39.104 | 3,551.373 | 84.072x |
| AVX2/BMI2 | 128 | 8,192 | 2,777,696 | 5,242,880 | 0.530 | 210.901 | 24.040 | 13,431.583 | 376.484x |

## 解釈

既定stride 32では、1,048,576要素の論理格納容量は完全packed inverse方式の
54.2%で、約45.8%削減されました。forward accessは同じpacked payloadを読むため
基準実装と同程度です。

inverse lookupは容量との明確なtrade-offがあります。stride 8から128へ広げると
容量比は58.8%から53.0%へ改善しますが、scalarのinverse時間は約1.17 usから
13.59 usへ増加しました。既定stride 32はscalarで約3.63 us/queryです。

buildは入力検証、cycle抽出、landmark用rank/select構築を含むため、完全inverseを
直接構築する基準より約2.2–2.7倍遅い結果でした。SIMDはlandmark rankを含む
inverseを一部改善しますが、forward traversalが支配的なため効果は限定的です。

## 制約

単一ホスト・固定順序での測定です。長い単一cycleはlandmarkを継続利用するケースであり、
短いcycleやcycle長の混在は測っていません。CPU周波数を固定していないため、数%の差を
一般化できません。RSS、allocator overhead、C++/JavaScript backend、他OS/CPUは未測定です。
