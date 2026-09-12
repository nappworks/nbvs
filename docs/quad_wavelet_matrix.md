# QuadWaveletMatrix

`QuadWaveletMatrix` is a 4-way Wavelet Matrix for unsigned integers. Each level
consumes two value bits, so a fixed-width 64-bit index uses 32 QuadVector levels
instead of 64 SuccinctBitVector levels.

## Cache-oriented layout

The heap-owned type keeps its level descriptors and four bucket starts in fixed
32-entry arrays. This removes the growable level-descriptor sequence from the
query path. The routing table is at most 32 x 4 x 8 = 1024 bytes.

Each query still follows a data-dependent path through the levels, but the
maximum dependency depth is halved:

```text
Binary WM 64-bit: 64 level transitions
Quad WM   64-bit: 32 level transitions
```

The underlying QuadVector rank dictionary uses one 64-byte metadata record per
4096 symbols. On the mmap path those records are 64-byte aligned.

`accessRank` is provided as a fused traversal returning both the decoded value
and its rank before the requested position. `rankPair` similarly computes two
rank endpoints in one traversal.

## Basic API

```nim
import nbvs/quad_wavelet_matrix

let values = @[5'u64, 1, 7, 5, 2, 9, 1]
let qwm = genQuadWaveletMatrix(values)

doAssert qwm[2] == 7
doAssert qwm.rank(5, qwm.n) == 2
doAssert qwm.select(1, 1) == 6
doAssert qwm.quantile(0, qwm.n, 3) == 5
```

A fixed bit width can be specified to compare directly with `WaveletMatrix`:

```nim
let qwm64 = genQuadWaveletMatrix(values, 64)
doAssert qwm64.levelCount == 32
```

The current API includes `access`, `accessRank`, `rank`, `rankPair`,
`rankIncl`, `rankLessThan`, `occPosition`, `select`, `selectNth`, `quantile`,
`countLessThan`, `rangeFreq`, `predecessor`, `successor`, `items`, and `toSeq`.

## mmap / external-memory view

`QuadWaveletMatrixView` can place the routing table and all QuadVectorView levels
in one external contiguous region.

```text
64-byte aligned base
├─ routing table: 4 x int64 per QWM level
├─ 64-byte padding
├─ QuadVectorView level 0
├─ 64-byte padding
├─ QuadVectorView level 1
│  ...
└─ QuadVectorView level N-1
```

Each QuadVectorView level itself stores its 2-bit payload, aligned rank metadata,
and select samples contiguously.

```nim
import std/memfiles
import nbvs/quad_wavelet_matrix

let values = @[5'u64, 1, 7, 5, 2, 9, 1]
let bitWidth = 64
let bytes = requiredQuadWaveletMatrixViewBytes(int64(values.len), bitWidth)
var mapped = memfiles.open("qwm.dat", mode = fmReadWrite,
  newFileSize = bytes)
try:
  var view = initQuadWaveletMatrixView(mapped.mem, mapped.size,
    int64(values.len), bitWidth)
  view.build(values)
  doAssert view.select(5, 1) == 3
finally:
  mapped.close()
```

Reopen persisted data with `built = true`:

```nim
var mapped = memfiles.open("qwm.dat", mode = fmReadWrite)
try:
  let view = initQuadWaveletMatrixView(mapped.mem, mapped.size,
    int64(values.len), bitWidth, built = true)
  doAssert view.rank(5, view.n) == 2
finally:
  mapped.close()
```

The QWM routing table contains enough information to reconstruct the four symbol
counts of every QuadVector level. Therefore `built = true` rebuilds runtime view
descriptors without rescanning every level payload. The mapped region remains
owned by the caller and must stay mapped while the view is used.

## Benchmark

The end-to-end comparison uses the same input values and exact same query stream
for Binary WaveletMatrix and QuadWaveletMatrix. Before timing, sampled
`access`, `accessRank`, `rank`, and `select` results are asserted equal.

```sh
nimble benchWmQwm
nimble benchWmQwmSimd
```

The benchmark reports build latency, payload/auxiliary bytes, and p50 latency for
`access`, `accessRank`, `rank`, and `select`. Cases include 65K, 1M, and 16M
values plus 16/32/64-bit fixed-width inputs so cache-size and level-count effects
can be separated.