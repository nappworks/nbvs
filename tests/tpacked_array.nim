import std/sequtils
import nbvs/packed_array

block uncheckedAccess:
  var values = genPackedArray(97, 9)
  for index in 0..<97:
    values[index] = uint64((index * 37) mod 512)
  for index in 0..<97:
    doAssert values.getUnchecked(index) == values[index]
import ./test_common

block helpers:
  doAssert ceilDiv(0, 64) == 0
  doAssert ceilDiv(1, 64) == 1
  doAssert ceilDiv(64, 64) == 1
  doAssert ceilDiv(65, 64) == 2
  doAssert maskForWidth(0) == 0'u64
  doAssert maskForWidth(1) == 1'u64
  doAssert maskForWidth(13) == 8191'u64
  doAssert maskForWidth(64) == uint64.high
  expectRaises(ValueError): discard maskForWidth(-1)
  expectRaises(ValueError): discard maskForWidth(65)

block constructor:
  let empty = genPackedArray(0, 7)
  doAssert empty.len == 0
  doAssert empty.bitWidth == 7
  doAssert empty.data.len == 0

  let z = genPackedArray(10, 0)
  doAssert z.len == 10
  doAssert z.bitWidth == 0
  doAssert z.data.len == 0
  doAssert z.maxValue == 0

  expectRaises(ValueError): discard genPackedArray(-1, 1)
  expectRaises(ValueError): discard genPackedArray(1, -1)
  expectRaises(ValueError): discard genPackedArray(1, 65)

block bitWidth0:
  var a = genPackedArray(10, 0)
  for i in 0'i64..<10:
    doAssert a[i] == 0
  a[0] = 0
  a.fill(0)
  doAssert a.toSeq == @[0'u64, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  doAssert $a == "@[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]"
  expectRaises(ValueError): a[0] = 1
  expectRaises(ValueError): a.fill(1)

block widthsAndCrossing:
  for width in [1, 2, 3, 7, 8, 9, 13, 16, 17, 31, 32, 33, 63, 64]:
    var a = genPackedArray(130, width)
    let mask = maskForWidth(width)
    doAssert a.maxValue == mask
    for i in 0'i64..<a.len:
      let v = (uint64(i) * 11400714819323198485'u64 + 12345'u64) and mask
      a[i] = v
    for i in 0'i64..<a.len:
      let expected = (uint64(i) * 11400714819323198485'u64 + 12345'u64) and mask
      doAssert a.get(i) == expected
      doAssert a[i] == expected

block overwriteAndFill:
  var a = genPackedArray(50, 9)
  a.fill(511)
  for i in 0'i64..<50:
    doAssert a[i] == 511
  for i in 0'i64..<50:
    a[i] = uint64(i)
  doAssert a.toSeq[0] == 0
  doAssert a.toSeq[49] == 49
  doAssert $genPackedArray(0, 3) == "@[]"

block fillAllWidthsAndTails:
  for width in 1..64:
    let mask = maskForWidth(width)
    let value = 0xa5a5_a5a5_a5a5_a5a5'u64 and mask
    for length in [1'i64, 2, 63, 64, 65, 130]:
      var a = genPackedArray(length, width)
      a.fill(value)
      doAssert a.toSeq == newSeqWith(int(length), value)
      a.fill(0)
      doAssert a.toSeq == newSeq[uint64](int(length))

block errors:
  var a = genPackedArray(3, 2)
  expectRaises(IndexDefect): discard a[-1]
  expectRaises(IndexDefect): discard a[3]
  expectRaises(IndexDefect): a[-1] = 0
  expectRaises(IndexDefect): a[3] = 0
  expectRaises(IndexDefect): a.checkIndex(3)
  expectRaises(ValueError): a[0] = 4
  expectRaises(ValueError): a.fill(4)

echo "OK tpacked_array"
