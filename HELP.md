# nbvs Help

This help file is the short English guide for `nbvs`.

## Quick start

`SuccinctBitVector` uses the portable scalar backend by default. Build with
`-d:nbvsSimd` to use the AVX2/BMI2 backend on a supported x86/x86_64 CPU.

```nim
import nbvs

var sbv = genSuccinctBitVector(128)
sbv[0] = true
sbv[64] = true
sbv.build()

doAssert sbv.rank1(65) == 2
doAssert sbv.select1(1) == 64
```

## Data structures

### BitVector

Use `BitVector` when you need a small mutable bit vector without rank/select indexes.

```nim
var bv = genBitVector(8)
bv[3] = true
doAssert bv[3]
```

### PackedArray

Use `PackedArray` when all values fit in the same bit width.

```nim
var a = genPackedArray(4, 5)
a[0] = 31
doAssert a[0] == 31
```

### SuccinctBitVector

Use `SuccinctBitVector` when you need `rank` and `select`.

```nim
var sbv = genSuccinctBitVector(10)
sbv[1] = true
sbv[7] = true
sbv.build()

doAssert sbv.rank1(8) == 2
doAssert sbv.select1(0) == 1
doAssert sbv.select0(0) == 0
```

### EliasFano

Use `EliasFano` for sorted integer sequences.

```nim
let ef = genEliasFano(@[1'u64, 3, 3, 10], 16)
doAssert ef.lowerBound(3) == 1
doAssert ef.upperBound(3) == 3
doAssert ef.predecessor(9) == 3
```

### WaveletMatrix

Use `WaveletMatrix` for rank/select, quantile, and range queries over an
arbitrary unsigned integer sequence.

```nim
let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2])
doAssert wm.rank(5, 5) == 2
doAssert wm.rankIncl(5, 3) == 2
doAssert wm.rankLessThan(5, 5) == 2
doAssert wm.selectNth(5, 2) == 3
doAssert wm.select(5, 1) == 3
doAssert wm.quantile(0, 5, 2) == 5
doAssert wm.rangeFreq(0, 5, 2, 8) == 4
```

Both `WaveletMatrix` and `ReversedWaveletMatrix` provide `valueCounts()` and
`valueCounts(left, right)`, returning sorted `(value, frequency)` pairs.

### ReversedWaveletMatrix

Use `ReversedWaveletMatrix` when levels must be constructed from LSB to MSB.

```nim
let rwm = genReversedWaveletMatrix(@[5'u64, 1, 7, 5, 1])
doAssert rwm.rank(1, 5) == 2
doAssert rwm.rankIncl(5, 3) == 2
doAssert rwm.rankLessThan(5, 5) == 2
doAssert rwm.select(5, 1) == 3
doAssert rwm.selectNth(5, 2) == 3
doAssert rwm.valueCounts[0] == (value: 1'u64, frequency: 2'i64)
```

## Common errors

- Call `build()` after mutating `SuccinctBitVector` and before using `rank` or `select`.
- `EliasFano` input must be nondecreasing.
- `EliasFano` uses an exclusive universe: every `x` must satisfy `x < universe`.
- `PackedArray` rejects values that do not fit in `bitWidth`.
- `WaveletMatrix` ranges use half-open `[left, right)` / `[lower, upper)` semantics.

## Generate API docs

```sh
nimble docs
```

Open the generated files under `docs/api/`.
