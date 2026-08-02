import std/strformat
import nbvs/succinct_bit_vector

const sizes = [512'i64, 4096, 65_536, 1_048_576, 16_777_216, 134_217_728]

echo "bits,raw_bytes,rank_prefix_bytes,object_metadata_bytes,total_logical_bytes,overhead_ratio"
for bits in sizes:
  let sbv = genSuccinctBitVector(bits)
  let raw = int64(sbv.data.len * sizeof(uint64))
  let auxiliary = int64(sbv.wordPairPrefix.len * sizeof(uint32) +
    sbv.blockPairPrefix.len * sizeof(uint32) +
    sbv.selectStorage.len * sizeof(uint64))
  let total = int64(sizeof(SuccinctBitVector)) + raw + auxiliary
  let ratio = if raw == 0: 0.0 else: float(auxiliary) / float(raw)
  echo &"{bits},{raw},{auxiliary},{sizeof(SuccinctBitVector)},{total},{ratio:.6f}"
