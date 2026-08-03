# Select optimization comparison

## 現行実装とbaseline

Select treeのdepth-first配置、32-byte node、512-bit leaf、PDEPによるword内selectは維持した。
対象は16,777,216 bits、50%密度、2,000,000 random queryで、baseline/candidateの順を
交互にした10試行の中央値を主要値とした。WSL2のためCPU affinityは固定できていない。

| backend | API | baseline | final candidate | 変化 |
|:---|:---|---:|---:|---:|
| Scalar | select1 | 136.339 ns | baselineと同一経路 | 変更なし |
| Scalar | select0 | 213.793 ns | baselineと同一経路 | 変更なし |
| SIMD | select1 | 109.848 ns | 110.662 ns | -0.7% |
| SIMD | select0 | 154.234 ns | 111.704 ns | +27.6% |

checksumは全測定で `41678230` と一致した。

## 段階profile

16,777,217 bits、50%密度、100,000 queryでtree depthは5だった。leaf word offset 0〜7は
各約12%〜13%でほぼ均等であり、後方wordを避けられない。末尾targetを明示的に含め、
partial block経路も確認した。profileは `select_stage_profile_*.json` に保存した。

## AVX2 leaf探索

2回のAVX2 load、nibble popcount、stack storeを試した。SIMD `select1` は107.744→119.017ns、
`select0` は147.563→171.950nsへ悪化した。8回のScalar POPCNTがこのCPUでは高速だった。

判断：見送り

## Valid child計算

生成Cでは各levelの `ceilDiv` が汎用関数callと整数除算を残していた。SIMD経路に限り、
full-node fast pathとpower-of-two shiftでvalid child数を求めるよう変更した。
Scalarでもselect0は改善したが、binary layoutによりselect1の非劣化条件を満たさなかったため、
Scalar経路は元へ戻した。

判断：条件付き適用
条件：SIMD backendのみ。

## Zero offset dispatch

生成Cに `offsetVecI32x8(childSize)` のruntime switchが残っていた。SIMDの製品経路だけを
static level templateへ切り替え、`select0` は126.020→120.014ns、binaryは160 bytes縮小した。
公開されている汎用helperは互換性のため維持した。

判断：適用

## Valid maskと限定inline

`validMaskI16Lanes` と `validMaskI32Lanes` のcallが生成Cに残っていたため、この2関数だけを
inline化した。`select0` は120.014→109.449ns、binaryは126,848→126,680 bytes、compile timeは
3.168→3.119秒となった。full-nodeは即値maskとなるため、mask tableは追加しなかった。

判断：適用

## Scalar early break

単調prefixを利用したearly breakを試したが、leaf offsetが均等で分岐予測コストが増えた。
`select1` は129.823→153.566ns、`select0` は173.558→203.970nsへ悪化した。

判断：見送り

## Static traversal

完全なlevel別展開は0〜8の経路を複製する。hot pathで確認された除算とoffset switchを除去した後は、
予測可能なlevel条件だけが残る。以前の強制inlineでcompile timeと実行性能が悪化した結果も踏まえ、
製品変更を行うだけの根拠がないと判断した。

判断：見送り

## PDEPと生成コード

`pdepU64` はPDEP一命令、`countTrailingZeroBits` はTZCNT一命令へ展開されていた。
word内selectは変更していない。

## 上位構造

単発の同一環境比較では、WM/RWM selectの多くのケースで約5%〜15%改善した。
SIMD WMの4,194,304要素ケースだけはノイズを含む悪化値だったため、安定測定の追加対象とする。
Elias–FanoのlowerBound、upperBound、predecessorは多くのケースで大幅に改善した。
Scalar候補値は採用前の実験値であり、最終Scalar製品経路はbaselineと同一である。

## Memory・binary・compile time

field、seq、Select tree、補助indexを追加していないため保持メモリは不変である。
SIMD benchmark binaryは127,008→126,680 bytes、compile timeは3.512→3.119秒だった。
Scalar binaryは130,696 bytesでbaselineと一致した。

## 最終判断

SIMD `select0` のvalid child shift、static zero offset、valid mask限定inlineを採用する。
AVX2 leaf探索、Scalar early break、完全static traversal、mask tableは見送る。
public API、Select semantics、保持形式、計算量は変更しない。
