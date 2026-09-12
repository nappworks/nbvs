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
改善した。buildはscalarで同等、SIMDで約5〜8%遅かった。

query全体の傾向、levelを9段から5段へ削減できること、および容量増が約3.6%に
留まることから、非RLE時の`fbpAuto`にHybridを採用する現行方針を維持する。

## rev3 / rev5

- `fm_dictionary_rev3_pr18.csv`: 100,000 strings、average length 16、
  10 corpus × Binary / Hybrid / RLE / Auto
- `fm_dictionary_rev5_pr18.csv`: random corpus 100,000 strings、average length 16、
  pattern length 8、suffix 10,000 queries、4 preference

rev3ではAutoがlog-message-like corpusでRLE、それ以外でHybridを選択した。
これは推定容量に基づく現在の選択条件と一致する。
