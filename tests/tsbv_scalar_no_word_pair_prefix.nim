import nbvs/succinct_bit_vector

# scalar/SIMDの両backendで、旧rank専用prefixを自動生成しないことを確認します。
# 65,332は指定された回帰確認値、65,536/65,537はlevel境界、
# 4,194,304/4,194,305は旧SIMD blockPairPrefix生成境界です。
for bitLength in [
    0'i64, 1, 65_332, 65_536, 65_537, 1_000_000,
    4_194_304, 4_194_305, 16_777_216
  ]:
  var sbv = genSuccinctBitVector(bitLength)
  doAssert sbv.wordPairPrefix.len == 0
  doAssert sbv.blockPairPrefix.len == 0

  if bitLength > 0:
    sbv[0] = true
    sbv[bitLength - 1] = true
  sbv.build()

  doAssert sbv.wordPairPrefix.len == 0
  doAssert sbv.blockPairPrefix.len == 0
  if bitLength > 0:
    doAssert sbv.rank1(bitLength) == (if bitLength == 1: 1 else: 2)

echo "OK tsbv_no_rank_only_prefix"
