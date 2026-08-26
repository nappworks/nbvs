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
| Scalar | 4 | 250,000 | 42,074,367 | 35,139,043 | 1.197x | 168.297 | 140.556 |
| Scalar | 100 | 10,000 | 10,207,577 | 8,029,776 | 1.271x | 1,020.758 | 802.978 |
| Scalar | 1,000 | 1,000 | 1,176,655 | 991,347 | 1.187x | 1,176.655 | 991.347 |
| Scalar | 10,000 | 100 | 204,809 | 167,008 | 1.226x | 2,048.090 | 1,670.080 |
| AVX2/BMI2 | 4 | 250,000 | 26,253,074 | 20,422,168 | 1.286x | 105.012 | 81.689 |
| AVX2/BMI2 | 100 | 10,000 | 4,910,883 | 3,561,298 | 1.379x | 491.088 | 356.130 |
| AVX2/BMI2 | 1,000 | 1,000 | 695,741 | 507,557 | 1.371x | 695.741 | 507.557 |
| AVX2/BMI2 | 10,000 | 100 | 123,390 | 81,893 | 1.507x | 1,233.900 | 818.930 |

## Acceptance

Cardinality 4 and 100 show no regression. Cardinality 1,000 and 10,000 improve,
but neither backend meets the requested 2.0x speedup. The current cursor removes
the repeated forward rank traversal, while every occurrence still performs the
reverse select traversal through all levels. Further improvement requires a
sequential select accelerator below the Wavelet Matrix layer rather than an API
or benchmark-only change.
