# Wavelet select cursor performance

## Environment

- nbvs SHA: `1e10ed2475c0bf5934f50857f28f8b4aadfacea8`
- Working tree before measurement: `clean`
- Nim: `2.2.10` (`bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef`)
- OS: `Linux 5.15.146.1-microsoft-standard-WSL2 x86_64`
- CPU: `Intel(R) Core(TM) i5-8365U CPU @ 1.60GHz`
- Rows: `1,000,000`
- Cardinality: `4 / 100 / 1,000 / 10,000`
- Repeats: `21`
- Memory manager: ARC

## Commands

Scalar:

```sh
nim c --path:src -d:release --mm:arc benchmarks/wm_select_cursor_perf.nim
./benchmarks/wm_select_cursor_perf
```

AVX2/BMI2:

```sh
nim c --path:src -d:release -d:nbvsSimd --mm:arc benchmarks/wm_select_cursor_perf.nim
./benchmarks/wm_select_cursor_perf
```

## Results

Raw results are available in
[`wm_select_cursor_scalar.csv`](wm_select_cursor_scalar.csv) and
[`wm_select_cursor_simd.csv`](wm_select_cursor_simd.csv).

| Backend | Cardinality | Occurrences | Normal p50 (ns) | Cursor p50 (ns) | Speedup | Normal ns/occurrence | Cursor ns/occurrence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Scalar | 4 | 250,000 | 34,573,761 | 29,406,778 | 1.176x | 138.295 | 117.627 |
| Scalar | 100 | 10,000 | 8,025,794 | 6,630,091 | 1.211x | 802.579 | 663.009 |
| Scalar | 1,000 | 1,000 | 1,018,476 | 848,363 | 1.201x | 1,018.476 | 848.363 |
| Scalar | 10,000 | 100 | 225,316 | 185,014 | 1.218x | 2,253.160 | 1,850.140 |
| AVX2/BMI2 | 4 | 250,000 | 21,928,262 | 17,184,403 | 1.276x | 87.713 | 68.738 |
| AVX2/BMI2 | 100 | 10,000 | 4,007,004 | 2,886,219 | 1.388x | 400.700 | 288.622 |
| AVX2/BMI2 | 1,000 | 1,000 | 550,442 | 402,331 | 1.368x | 550.442 | 402.331 |
| AVX2/BMI2 | 10,000 | 100 | 97,308 | 70,205 | 1.386x | 973.080 | 702.050 |

## Acceptance

Cardinality 4 and 100 show no regression. Cardinality 1,000 and 10,000 improve,
but neither backend meets the requested 2.0x speedup. The current cursor removes
the repeated forward rank traversal, while every occurrence still performs the
reverse select traversal through all levels. Further improvement requires a
sequential select accelerator below the Wavelet Matrix layer rather than an API
or benchmark-only change.
