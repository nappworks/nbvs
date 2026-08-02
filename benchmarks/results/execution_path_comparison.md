# Execution path optimization comparison

## 方針

Scalar/SIMD固有のrank補助構造、raw bit data、select treeの論理形式は維持した。
追加の恒常的indexやquery cacheは導入していない。

## Rank pair

同一512-bit blockで上位prefix走査を共有する `rank1PairUnchecked` を試作し、
`wm_range_rank_perf.nim` で評価した。Scalarの20-bitケースだけは改善したが、
Scalar 8-bitとRWM、SIMDの両ケースで悪化した。fallback判定とtuple/function境界の
固定費がrandom rangeで回収できなかった。

判断：見送り

## Access-rank融合

bit読出しとrankをtupleで返す経路をWM/RWMへ適用した。現行rank実装の内部word loadを
直接再利用するにはrank hot pathの大規模な複製が必要で、単純なhelperでは生成コードに
rank呼出しが残った。Rank pairとの組合せ測定でも非劣化条件を満たさなかった。

判断：見送り

## Build初期化

従来の `resetLevels` はbuild直前にselect tree全体をsentinelで埋め、その直後に全論理entryを
上書きしていた。採用実装は各levelの末尾paddingだけをsentinelへ戻す。論理entry、保持容量、
allocation数、計算量は変わらない。直接SBV benchmarkではScalarで約15.8%〜45.2%、SIMDで
約30.3%〜53.8% build時間を短縮した。checksumは双方 `41678230` で一致した。

判断：適用

## Inline

rank prefixと融合helperの強制inlineはScalar compile 3.097sから7.890s、SIMD 3.252sから
8.755sへ増加し、代表range rankも大幅に悪化した。

判断：見送り

## Storage field

field統合はhot pathの追加index計算を伴い、今回の目的である保持構造維持にも反するため変更しない。
保持メモリはbaselineとcandidateで同一である。

判断：見送り

## Compiler options

GCC releaseのARC、ORC、`-march=native`、LTOを比較した。`-march=native` は一部で改善したが
portable性を失うためbenchmark専用とする。ORCとLTOは代表ケースで一貫した改善がなかった。
Clangは実行環境に未導入で比較できなかった。

判断：条件付き適用
条件：`-march=native` はローカルbenchmarkに限る。

## 回帰とメモリ

WM、RWM、Elias–Fanoを含む既存Scalar/SIMDテストを実行した。query本体は最終差分に含まれず、
論理メモリ、object metadata、seq数、保持データは変更されない。WM/RWM benchmarkでもstorage MiBは
baselineとcandidateで一致した。WSL2上の単発query値にはセッションノイズがあるため、query改善とは
判定せず、コード同一性とテスト結果を非劣化の根拠とした。

## 最終判断

padding限定初期化だけを採用する。Rank pair、access-rank融合、強制inline、storage field変更は
本体からrollback済みである。prefix形式やbackend共通化は今後も優先検討領域としない。
