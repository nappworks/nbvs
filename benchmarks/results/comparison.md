# SuccinctBitVector prefix comparison

測定環境、固定seed、query数（各200万回）は変更前後で同一です。buildは20反復の
平均です。WSL2上でCPU周波数を固定できないため、値には環境ノイズを含みます。

## 16 Mi bit・密度50%の速度比

速度比は `baseline time / candidate time` です。

| Prefix | Backend | build | rank1 random | select1 random | select0 random |
| ---: | --- | ---: | ---: | ---: | ---: |
| 4096 | Scalar | 0.534 | 0.212 | 0.396 | 0.508 |
| 4096 | SIMD | 1.490 | 0.708 | 0.843 | 0.715 |
| 2048 | Scalar | 0.574 | 0.363 | 0.511 | 0.624 |
| 2048 | SIMD | 3.564 | 1.014 | 1.070 | 0.911 |

4096-bit案の補助payloadはScalar 205,984 bytes、SIMD 140,448 bytesから、
双方32,776 bytes（raw比1.563%）へ削減できます。2048-bit案は約3.126%です。

## 判断

見送り。4096-bit案はScalar/SIMD rankの許容値を満たさず、2048-bit案もScalar
rankとbuildが許容値を大きく下回ります。Scalarだけ細粒度prefixを追加する案は
共通構造という必須条件および禁止事項に反するため採用しません。本体はbaselineへ
戻し、測定harnessと結果だけを保持します。
