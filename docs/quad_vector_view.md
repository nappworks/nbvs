# QuadVectorView

`QuadVectorView` is the non-owning external-memory counterpart of `QuadVector`.
It supports the same mutable payload workflow and rank/select query semantics over
caller-owned contiguous memory, including memory mapped with `std/memfiles`.

## Layout

Use `requiredQuadVectorViewBytes(maxSymbols)` to obtain the required backing size,
then pass the mapped address and size to `initQuadVectorView`.

The backing layout is:

```text
64-byte aligned base
├─ 2-bit symbol payload
├─ alignment padding to 64 bytes
├─ rank metadata: 64 bytes per 4096-symbol superblock
└─ select sample storage
```

The base address must be 64-byte aligned. Normal mmap base addresses satisfy this
requirement. The alignment keeps every 64-byte rank metadata record cache-line
aligned and also gives the packed payload an AVX2-friendly base address.

The rank metadata has the same logical 6.25% payload overhead as `QuadVector`.
Select samples use 32-bit sampled superblock IDs every 1024 occurrences. The
view reserves the minimum worst-case number of 64-bit words needed before symbol
frequencies are known; the actual per-symbol `PackedArrayView` descriptors are
bound after `build()` or reconstructed when reopening with `built = true`.
Alignment padding and small tail rounding are therefore included in
`backingBytes` but are outside the asymptotic 7.8125% auxiliary target.

## mmap example

```nim
import std/memfiles
import nbvs/[quad_vector_view]

let n = 1_000_000'i64
let bytes = requiredQuadVectorViewBytes(n)
var mapped = memfiles.open("quad.dat", mode = fmReadWrite,
  newFileSize = bytes)
try:
  var qv = initQuadVectorView(mapped.mem, mapped.size, n)
  for i in 0'i64..<n:
    qv[i] = uint8(i and 3)
  qv.build()

  doAssert qv.rank2(n) == n div 4
  doAssert qv.select3(0) == 3
finally:
  mapped.close()
```

To reopen the persisted payload and dictionaries without rebuilding them:

```nim
var mapped = memfiles.open("quad.dat", mode = fmReadWrite)
try:
  let qv = initQuadVectorView(mapped.mem, mapped.size, n, built = true)
  doAssert qv.rank2(n) == n div 4
finally:
  mapped.close()
```

`built = true` reconstructs runtime-only `totalCounts` and the four select-sample
descriptors from the persisted 2-bit payload, while reusing the rank/select
metadata already stored in the mapping. The mapped memory must not be modified
between the persisted `build()` and reopening as built metadata.

## Ownership and lifetime

`QuadVectorView` never owns, unmaps, closes, or frees the supplied memory. Keep
the mapping or other backing allocation alive and at a stable address for the
entire lifetime of the view.

The public query surface mirrors `QuadVector`: `access`, `[]`, `[]=`,
`setSymbol`, `clearSymbol`, `build`, `rank`, `rankIncl`, `rank0..rank3`,
`rank0Incl..rank3Incl`, `select`, and `select0..select3`.