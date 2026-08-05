## FmDictionaryで使用する9-bit symbolの定義と変換処理。

type
  FmSymbol* = uint16
    ## 通常byteとシステムsymbolを分離して表す型です。

const
  EndSymbol* = 0'u16
  SeparatorSymbol* = 257'u16
  AlphabetSize* = 258
  SymbolBitWidth* = 9

func encodeByte*(value: byte): FmSymbol {.inline.} =
  ## byteをシステムsymbolと衝突しない範囲へ変換します。
  FmSymbol(value) + 1

func decodeByte*(symbol: FmSymbol): byte {.inline.} =
  ## 通常byteのsymbolを元のbyteへ戻します。
  ##
  ## システムsymbolを渡した場合は `AssertionDefect` が発生します。
  doAssert symbol >= 1 and symbol <= 256
  byte(symbol - 1)

func encodeString*(value: string): seq[FmSymbol] =
  ## 文字列をUTF-8のcode pointではなくbyte単位でsymbol列へ変換します。
  result = newSeq[FmSymbol](value.len)
  for index, character in value:
    result[index] = encodeByte(byte(character))
