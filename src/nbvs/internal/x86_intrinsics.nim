## Minimal AVX2/BMI2 intrinsic bindings used by nbvs.
##
## This module intentionally avoids `nimsimd`.  It exposes only the small
## subset of x86 intrinsics required by `succinct_bit_vector.nim`.
##
## This module is internal; its exported symbols are implementation details and
## may change without notice.

when not (defined(amd64) or defined(i386)):
  {.error: "nbvs AVX2/BMI2 backend requires an x86 or x86_64 target".}

when defined(gcc) or defined(clang):
  {.localPassc: "-mavx2".}
  {.localPassc: "-mbmi2".}

when defined(vcc):
  {.localPassc: "/arch:AVX2".}

type
  M256i* {.importc: "__m256i", header: "<immintrin.h>", bycopy.} = object ## Imported AVX2 256-bit integer vector type.
  M256* {.importc: "__m256", header: "<immintrin.h>", bycopy.} = object ## Imported AVX 256-bit float vector type used for masks.

## Binds `_mm256_setr_epi8`.
proc mm256_setr_epi8*(
  e00, e01, e02, e03, e04, e05, e06, e07: int8,
  e08, e09, e10, e11, e12, e13, e14, e15: int8,
  e16, e17, e18, e19, e20, e21, e22, e23: int8,
  e24, e25, e26, e27, e28, e29, e30, e31: int8
): M256i {.importc: "_mm256_setr_epi8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_set1_epi8`.
proc mm256_set1_epi8*(a: int8): M256i
  {.importc: "_mm256_set1_epi8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_set1_epi16`.
proc mm256_set1_epi16*(a: int16): M256i
  {.importc: "_mm256_set1_epi16", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_set1_epi32`.
proc mm256_set1_epi32*(a: int32): M256i
  {.importc: "_mm256_set1_epi32", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_setr_epi16`.
proc mm256_setr_epi16*(
  e00, e01, e02, e03, e04, e05, e06, e07: int16,
  e08, e09, e10, e11, e12, e13, e14, e15: int16
): M256i {.importc: "_mm256_setr_epi16", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_setr_epi32`.
proc mm256_setr_epi32*(
  e00, e01, e02, e03, e04, e05, e06, e07: int32
): M256i {.importc: "_mm256_setr_epi32", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_loadu_si256`.
proc mm256_loadu_si256*(p: ptr M256i): M256i
  {.importc: "_mm256_loadu_si256", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_storeu_si256`.
proc mm256_storeu_si256*(p: ptr M256i, a: M256i)
  {.importc: "_mm256_storeu_si256", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_and_si256`.
proc mm256_and_si256*(a, b: M256i): M256i
  {.importc: "_mm256_and_si256", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_xor_si256`.
proc mm256_xor_si256*(a, b: M256i): M256i
  {.importc: "_mm256_xor_si256", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_srli_epi16`.
proc mm256_srli_epi16*(a: M256i, imm8: cint): M256i
  {.importc: "_mm256_srli_epi16", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_shuffle_epi8`.
proc mm256_shuffle_epi8*(a, b: M256i): M256i
  {.importc: "_mm256_shuffle_epi8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_add_epi8`.
proc mm256_add_epi8*(a, b: M256i): M256i
  {.importc: "_mm256_add_epi8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_sad_epu8`.
proc mm256_sad_epu8*(a, b: M256i): M256i
  {.importc: "_mm256_sad_epu8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_cmpgt_epi16`.
proc mm256_cmpgt_epi16*(a, b: M256i): M256i
  {.importc: "_mm256_cmpgt_epi16", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_cmpgt_epi32`.
proc mm256_cmpgt_epi32*(a, b: M256i): M256i
  {.importc: "_mm256_cmpgt_epi32", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_sub_epi16`.
proc mm256_sub_epi16*(a, b: M256i): M256i
  {.importc: "_mm256_sub_epi16", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_sub_epi32`.
proc mm256_sub_epi32*(a, b: M256i): M256i
  {.importc: "_mm256_sub_epi32", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_movemask_epi8`.
proc mm256_movemask_epi8*(a: M256i): cint
  {.importc: "_mm256_movemask_epi8", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_castsi256_ps`.
proc mm256_castsi256_ps*(a: M256i): M256
  {.importc: "_mm256_castsi256_ps", header: "<immintrin.h>", noSideEffect.}

## Binds `_mm256_movemask_ps`.
proc mm256_movemask_ps*(a: M256): cint
  {.importc: "_mm256_movemask_ps", header: "<immintrin.h>", noSideEffect.}

## Binds BMI2 `_pdep_u64`.
proc pdepU64*(a, mask: uint64): uint64
  {.importc: "_pdep_u64", header: "<immintrin.h>", noSideEffect.}
