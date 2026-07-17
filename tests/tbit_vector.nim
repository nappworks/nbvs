import nbvs/bit_vector
import ./test_common

block createAndAccess:
  var bv = genBitVector(10)
  doAssert bv.maxOfBits == 10
  doAssert bv.lenOfBits == 0
  doAssert $bv == ""

  bv.setBit(0)
  bv.setBit(9)
  doAssert bv.lenOfBits == 10
  doAssert bv[0]
  doAssert not bv[1]
  doAssert bv[9]
  doAssert $bv == "1000000001"

block clearAndAssign:
  var bv = genBitVector(16)
  bv[3] = true
  bv[7] = true
  doAssert $bv == "00010001"
  bv.clearBit(3)
  doAssert not bv[3]
  doAssert bv[7]
  bv[15] = false
  doAssert bv.lenOfBits == 16
  doAssert not bv[15]
  bv[15] = true
  doAssert bv[15]

block byteBoundary:
  var bv = genBitVector(17)
  for i in [0, 7, 8, 16]:
    bv[i] = true
  doAssert $bv == "10000001100000001"

block errors:
  expectRaises(ValueError): discard genBitVector(-1)
  var bv = genBitVector(2)
  expectRaises(IndexDefect): discard bv[-1]
  expectRaises(IndexDefect): discard bv[2]
  expectRaises(IndexDefect): bv[-1] = true
  expectRaises(IndexDefect): bv[2] = true
  expectRaises(IndexDefect): bv.setBit(2)
  expectRaises(IndexDefect): bv.clearBit(-1)

echo "OK tbit_vector"
