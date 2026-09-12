# PR #18 FmDictionary Hybrid Wavelet validation

測定日: 2026-09-12

- commit: `b5d8664`
- Nim: 2.2.10
- OS/CPU: Linux amd64 (WSL2 kernel 5.15.146.1)
- build: release, ARC
- A/B corpus: 100,000 strings, average length 16, 10,000 queries

## Binary WM / Hybrid A/B

全測定値は次のCSVに保存した。

- `fm_hybrid_wavelet_ab_scalar.csv`
- `fm_hybrid_wavelet_ab_simd.csv`

HybridのBWT容量はBinary WM比で1.0361倍だった。scalarのqueryは2 runとも
Hybridが高速だった。SIMDは`accessRank`、`rankPair`、suffix、restoreで2 runとも
Hybridが高速で、substringは1 runで0.9570倍へ悪化したが、もう1 runでは1.0929倍へ
改善した。buildはscalarで同等、SIMDで約5〜7%遅かった。

query全体の傾向、levelを9段から5段へ削減できること、および容量増が約3.6%に
留まることから、非RLE時の`fbpAuto`にHybridを採用する現行方針を維持する。

## rev3 / rev5

- `fm_dictionary_rev3_pr18.csv`: 100,000 strings、average length 16、
  10 corpus × Binary / Hybrid / RLE / Auto
- `fm_dictionary_rev5_pr18.csv`: random corpus 100,000 strings、average length 16、
  pattern length 8、suffix 10,000 queries、4 preference

rev3ではAutoがlog-message-like corpusでRLE、それ以外でHybridを選択した。
これは推定容量に基づく現在の選択条件と一致する。

## ShikiDB E2E

ShikiDBのローカルcheckoutで、このリポジトリの`src`を明示して検証した。

- `tests/test_fm_string_v2.nim`: 6 tests成功
- rows: 100,000
- cardinality: 10,000
- repeats: 5
- build + publish: 60.833 ms
- reopen FmDictionary rebuild: 50.110 ms
- exact String to ID lookup: 0.521 us/query
- equality count: 0.737 ms/query
- `.fms1`: 425,144 bytes
- backend: `fbHybridWavelet`
- FmDictionary memory: 344,172 bytes
- BWT length / runs: 180,002 / 42,011
- BWT run ratio: 0.233392
