import std/[memfiles, os, tempfiles]
import nbvs/packed_array
import ./test_common

block callerOwnedBuffer:
  var words: array[4, uint64]
  var view = initPackedArrayView(addr words[0], sizeof(words), 16, 13)
  doAssert view.len == 16
  doAssert view.bitWidth == 13
  doAssert view.dataWords == 4
  view[0] = 1234
  view[15] = 8191
  doAssert view.get(0) == 1234
  doAssert view.getUnchecked(15) == 8191

block constructorValidation:
  var word: uint64
  var alignedWords: array[2, uint64]
  let empty = initPackedArrayView(nil, 0, 0, 64)
  doAssert empty.dataWords == 0
  let zeroWidth = initPackedArrayView(nil, 0, 10, 0)
  doAssert zeroWidth.toSeq == newSeq[uint64](10)

  expectRaises(ValueError):
    discard initPackedArrayView(addr word, sizeof(word), -1, 1)
  expectRaises(ValueError):
    discard initPackedArrayView(addr word, sizeof(word), 1, -1)
  expectRaises(ValueError):
    discard initPackedArrayView(addr word, sizeof(word), 1, 65)
  expectRaises(ValueError):
    discard initPackedArrayView(addr word, -1, 1, 1)
  expectRaises(ValueError):
    discard initPackedArrayView(nil, sizeof(word), 1, 1)
  expectRaises(ValueError):
    discard initPackedArrayView(addr word, sizeof(word) - 1, 9, 8)
  expectRaises(ValueError):
    discard initPackedArrayView(
      cast[pointer](cast[uint](addr alignedWords[0]) + 1'u),
      sizeof(uint64), 1, 1)

block zeroWidthSemantics:
  var view = initPackedArrayView(nil, 0, 4, 0)
  doAssert view.maxValue == 0
  doAssert view[0] == 0
  doAssert view.get(3) == 0
  doAssert view.getUnchecked(2) == 0
  view.set(0, 0)
  view[1] = 0
  view.fill(0)
  doAssert $view == "@[0, 0, 0, 0]"
  expectRaises(ValueError): view[0] = 1
  expectRaises(ValueError): view.fill(1)

block heapAndMmapCompatibility:
  let tempDir = createTempDir("nbvs-packed-array-", "")
  let path = tempDir / "storage.bin"
  const storageBytes = 2048
  var mappedFile = memfiles.open(path, mode = fmReadWrite,
    newFileSize = storageBytes)
  try:
    for width in 0..64:
      for length in [1'i64, 2, 63, 64, 65, 97, 130]:
        zeroMem(mappedFile.mem, mappedFile.size)
        var heap = genPackedArray(length, width)
        var mapped = initPackedArrayView(mappedFile.mem, mappedFile.size,
          length, width)
        let mask = maskForWidth(width)

        doAssert heap.maxValue == mapped.maxValue
        heap.checkIndex(0)
        mapped.checkIndex(0)
        for i in 0'i64..<length:
          let value = (uint64(i) * 11400714819323198485'u64 + 12345'u64) and mask
          heap.set(i, value)
          mapped.set(i, value)
          doAssert heap.get(i) == mapped.get(i)
          doAssert heap[i] == mapped[i]
          doAssert heap.getUnchecked(int(i)) == mapped.getUnchecked(int(i))

        let fillValue = 0xa5a5_a5a5_a5a5_a5a5'u64 and mask
        heap.fill(fillValue)
        mapped.fill(fillValue)
        doAssert heap.toSeq == mapped.toSeq
        doAssert $heap == $mapped

        for i in 0'i64..<length:
          let first = uint64(i) and mask
          heap[i] = first
          mapped[i] = first
          let overwritten = (uint64(i) * 37'u64 + 11'u64) and mask
          heap[i] = overwritten
          mapped[i] = overwritten
        doAssert heap.toSeq == mapped.toSeq

        heap.fill(mask)
        mapped.fill(mask)
        for i in 0'i64..<length:
          heap[i] = uint64(i) and mask
          mapped[i] = uint64(i) and mask
        doAssert heap.toSeq == mapped.toSeq

        expectRaises(IndexDefect): discard heap.get(-1)
        expectRaises(IndexDefect): discard mapped.get(-1)
        expectRaises(IndexDefect): discard heap[length]
        expectRaises(IndexDefect): discard mapped[length]
        expectRaises(IndexDefect): heap.set(-1, 0)
        expectRaises(IndexDefect): mapped.set(-1, 0)
        expectRaises(IndexDefect): heap[length] = 0
        expectRaises(IndexDefect): mapped[length] = 0
        expectRaises(IndexDefect): heap.checkIndex(length)
        expectRaises(IndexDefect): mapped.checkIndex(length)
        if width < 64:
          let invalidValue = mask + 1'u64
          expectRaises(ValueError): heap[0] = invalidValue
          expectRaises(ValueError): mapped[0] = invalidValue
          expectRaises(ValueError): heap.fill(invalidValue)
          expectRaises(ValueError): mapped.fill(invalidValue)
  finally:
    mappedFile.close()
    removeFile(path)
    removeDir(tempDir)

block mmapPersistence:
  let tempDir = createTempDir("nbvs-packed-persistence-", "")
  let path = tempDir / "storage.bin"
  const storageBytes = 128
  var mappedFile = memfiles.open(path, mode = fmReadWrite,
    newFileSize = storageBytes)
  try:
    var view = initPackedArrayView(mappedFile.mem, mappedFile.size, 32, 13)
    view.fill(7)
    view[10] = 123
    view[20] = 456
    mappedFile.flush()
  finally:
    mappedFile.close()

  mappedFile = memfiles.open(path, mode = fmReadWrite)
  try:
    let reopened = initPackedArrayView(mappedFile.mem, mappedFile.size, 32, 13)
    doAssert reopened[0] == 7
    doAssert reopened[10] == 123
    doAssert reopened[20] == 456
    doAssert reopened[31] == 7
  finally:
    mappedFile.close()
    removeFile(path)
    removeDir(tempDir)

echo "OK tpacked_array_view"
