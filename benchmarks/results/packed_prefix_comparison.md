# 共通Packed二段Prefix検証

## 構造

候補は4096-bit superblockごとに16-byte entryを1件保持します。`lo`には33-bitの
絶対one countとsubblock 1・2の12-bit相対count、`hi`にはsubblock 3～7の相対countを
格納します。Scalar/SIMDでfield、payload、paddingは完全に同一です。最大長は既存の
8,589,934,592 bitを維持します。Select専用treeは候補から削除しました。

## メモリ

16 Mi bitではraw data 2,097,152 bytesに対し、候補prefixは65,536 bytes（3.125%）です。
現行Scalar 205,984 bytesから68.18%、現行SIMD 140,448 bytesから53.34%削減できます。

## 性能

16 Mi bit・密度50%・各200万queryを、固定したbaseline/candidateバイナリで交互に2回
実行した中央値です。詳細値は`packed_prefix_comparison.csv`を参照してください。

Scalarはbuild 1.710、rank 0.899、select1 0.679、select0 0.902で最低基準を満たしました。
SIMDはbuild 2.369、rank 0.804、select1 0.663、select0 0.837でした。rankは見送り閾値
0.85未満、select1も最低値0.80未満です。

Wavelet Matrix（1,048,576件、alphabet 256）のScalar候補はbaseline比でbuild 0.806、
access 0.778、rank 0.683、select 0.826でした。rankが最低値0.75を下回りました。
SIMD候補も同条件でbuild 0.816、access 0.795、rank 0.649、select 0.693となり基準未達です。

## ボトルネック

最大8-word scanへ短縮したことでScalar rankは前回4096-bit単段案の0.212から0.899へ
改善しました。一方、SIMDで8-word専用AVX2 popcountを使ってもrandom rankの走査は
通常0～7 full wordであり、多くがScalar pathへ落ちました。4-word AVX2化も試しましたが、
shuffle/SADと非inline関数境界の固定費が支配し、rankはさらに低下しました。Selectでは
packed absoluteのbinary search、7 relative fieldの逐次検索、word走査が累積しています。

## 最終判断

判断：見送り

理由：メモリ目標とScalar単体性能は満たしますが、SIMD rank/selectおよびWavelet Matrix
rank/selectが必須基準を満たしません。本体はbaselineへrollbackし、実験用packed entry、
測定結果、判断理由のみ保持します。
