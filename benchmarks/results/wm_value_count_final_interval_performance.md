# Wavelet value-count final interval performance

## Environment

- nbvs SHA: `9344930432cd7748bc3be58842604457302ccf8f`
- Working tree before measurement: `clean`
- Nim: `2.2.10` (`bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef`)
- OS: `Linux 5.15.146.1-microsoft-standard-WSL2 x86_64`
- CPU: `Intel(R) Core(TM) i5-8365U CPU @ 1.60GHz`
- Rows: `65,536 / 1,048,576`
- Cardinality: `4 / 100 / 1,000`
- Repeats: `11`
- Inner repeats: `10`
- Memory manager: ARC

## Command

The absolute source path ensures that the benchmark imports the working-tree
version of `nbvs`. Replace `<repository>` with the repository root.

```sh
nim c --path:<repository>/src -d:release --mm:arc \
  -r benchmarks/wm_value_count_interval_perf.nim
```

## Results

`collect counts` measures `collectValueCounts()`. `collect intervals` measures
`collectValueCountFinalIntervals()`. `counts + retraverse` first collects the
counts and then traverses every Wavelet Matrix level again for each distinct
value to recover its terminal interval.

| Rows | Cardinality | Bit width | Collect counts p50 (ns) | Collect counts p95 (ns) | Collect intervals p50 (ns) | Collect intervals p95 (ns) | Counts + retraverse p50 (ns) | Counts + retraverse p95 (ns) | Intervals / counts p50 | Intervals / counts p95 | Retraverse / intervals p50 | Retraverse / intervals p95 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 65,536 | 4 | 2 | 220 | 280 | 210 | 250 | 300 | 340 | 0.9545 | 0.8929 | 1.4286 | 1.3600 |
| 65,536 | 100 | 7 | 6,860 | 8,870 | 7,350 | 9,730 | 30,761 | 40,842 | 1.0714 | 1.0970 | 4.1852 | 4.1975 |
| 65,536 | 1,000 | 10 | 70,823 | 96,955 | 69,893 | 118,466 | 411,512 | 535,919 | 0.9869 | 1.2219 | 5.8877 | 4.5238 |
| 1,048,576 | 4 | 2 | 230 | 280 | 240 | 250 | 350 | 380 | 1.0435 | 0.8929 | 1.4583 | 1.5200 |
| 1,048,576 | 100 | 7 | 10,130 | 12,580 | 10,770 | 14,740 | 44,192 | 62,403 | 1.0632 | 1.1717 | 4.1032 | 4.2336 |
| 1,048,576 | 1,000 | 10 | 80,334 | 140,167 | 78,374 | 121,016 | 497,337 | 672,057 | 0.9756 | 0.8634 | 6.3457 | 5.5535 |

## Evaluation

The terminal-interval traversal stays close to the existing value-count
traversal: its p50 ratio is between `0.9545x` and `1.0714x` in all cases.

At cardinality 100 and 1,000, collecting terminal intervals directly is
`4.1032x` to `6.3457x` faster at p50 than collecting counts and re-traversing
the Wavelet Matrix for every value. Cardinality 4 has too little per-value
re-traversal work for a large separation, but direct collection remains close
to the existing traversal.

## Conclusion

The measurement confirms the expected relationship `A ≈ B << C` for high
cardinality inputs. Returning the terminal interval from the existing leaf
visit avoids a separate `bitWidth` traversal per distinct value without a
material cost over `collectValueCounts()`.
