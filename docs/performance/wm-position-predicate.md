# Wavelet Matrix position predicate performance

- Measured commit: `2ac0eac9c4fbb32c5270547757d233b5030f8fed`
- Environment: Intel(R) Core(TM) i5-8365U CPU @ 1.60GHz; linux/amd64
- Nim: 2.2.10
- Compile: `nim c -d:release --mm:arc --path:src -r benchmarks/wm_position_predicate_perf.nim`
- Rows: 1000000; probes/repeat: 100000; warmup: 1 repeat; measured repeats: 21

## Latency

All latency values are ns/probe. Delta is versus the matching `access` baseline; negative is faster.

| Matrix | Bits | Predicate | Workload (%) | Method | p50 | p95 | p99 | Delta |
| --- | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |
| WM | 8 | equality | 0 | access | 463.770 | 661.543 | 739.196 | +0.0% |
| WM | 8 | equality | 0 | matches_checked | 80.170 | 106.104 | 108.103 | -82.7% |
| WM | 8 | equality | 0 | matches_unchecked | 81.957 | 97.929 | 134.069 | -82.3% |
| RWM | 8 | equality | 0 | access | 448.507 | 547.268 | 550.803 | +0.0% |
| RWM | 8 | equality | 0 | matches_checked | 78.909 | 89.251 | 90.481 | -82.4% |
| RWM | 8 | equality | 0 | matches_unchecked | 75.668 | 84.689 | 86.373 | -83.1% |
| WM | 8 | equality | 1 | access | 479.263 | 682.534 | 698.321 | +0.0% |
| WM | 8 | equality | 1 | matches_checked | 88.374 | 112.699 | 113.868 | -81.6% |
| WM | 8 | equality | 1 | matches_unchecked | 90.463 | 124.351 | 129.751 | -81.1% |
| RWM | 8 | equality | 1 | access | 447.856 | 509.161 | 570.063 | +0.0% |
| RWM | 8 | equality | 1 | matches_checked | 87.159 | 100.292 | 106.173 | -80.5% |
| RWM | 8 | equality | 1 | matches_unchecked | 86.200 | 112.242 | 117.755 | -80.8% |
| WM | 8 | equality | 50 | access | 438.456 | 499.179 | 577.322 | +0.0% |
| WM | 8 | equality | 50 | matches_checked | 246.684 | 330.441 | 333.325 | -43.7% |
| WM | 8 | equality | 50 | matches_unchecked | 240.965 | 306.640 | 319.574 | -45.0% |
| RWM | 8 | equality | 50 | access | 448.526 | 482.969 | 518.093 | +0.0% |
| RWM | 8 | equality | 50 | matches_checked | 285.183 | 451.546 | 529.974 | -36.4% |
| RWM | 8 | equality | 50 | matches_unchecked | 245.183 | 256.453 | 258.805 | -45.3% |
| WM | 8 | equality | 100 | access | 448.010 | 606.025 | 664.620 | +0.0% |
| WM | 8 | equality | 100 | matches_checked | 399.020 | 468.319 | 514.415 | -10.9% |
| WM | 8 | equality | 100 | matches_unchecked | 394.362 | 488.860 | 500.296 | -12.0% |
| RWM | 8 | equality | 100 | access | 436.150 | 489.960 | 496.264 | +0.0% |
| RWM | 8 | equality | 100 | matches_checked | 407.293 | 565.764 | 569.793 | -6.6% |
| RWM | 8 | equality | 100 | matches_unchecked | 395.105 | 486.830 | 490.185 | -9.4% |
| WM | 8 | range | 0.1 | access | 448.842 | 511.141 | 584.296 | +0.0% |
| WM | 8 | range | 0.1 | range_unchecked | 72.413 | 114.101 | 129.790 | -83.9% |
| WM | 8 | range | 1 | access | 455.945 | 521.925 | 523.674 | +0.0% |
| WM | 8 | range | 1 | range_unchecked | 70.163 | 92.798 | 102.247 | -84.6% |
| WM | 8 | range | 10 | access | 476.899 | 657.478 | 982.226 | +0.0% |
| WM | 8 | range | 10 | range_unchecked | 69.833 | 76.596 | 76.888 | -85.4% |
| WM | 8 | range | 25 | access | 438.788 | 487.248 | 540.693 | +0.0% |
| WM | 8 | range | 25 | range_unchecked | 46.284 | 65.777 | 67.865 | -89.5% |
| WM | 8 | range | 40 | access | 436.321 | 493.775 | 571.783 | +0.0% |
| WM | 8 | range | 40 | range_unchecked | 95.731 | 133.675 | 152.847 | -78.1% |
| WM | 8 | range | 50 | access | 445.003 | 548.640 | 573.528 | +0.0% |
| WM | 8 | range | 50 | range_unchecked | 19.992 | 24.166 | 24.774 | -95.5% |
| WM | 8 | range | 75 | access | 440.549 | 483.274 | 523.148 | +0.0% |
| WM | 8 | range | 75 | range_unchecked | 41.982 | 53.847 | 64.035 | -90.5% |
| WM | 8 | range | 90 | access | 451.256 | 522.284 | 523.444 | +0.0% |
| WM | 8 | range | 90 | range_unchecked | 67.267 | 84.834 | 94.854 | -85.1% |
| WM | 8 | range | 100 | access | 432.134 | 475.795 | 507.659 | +0.0% |
| WM | 8 | range | 100 | range_unchecked | 7.417 | 9.796 | 11.265 | -98.3% |
| WM | 16 | equality | 0 | access | 1106.031 | 1451.564 | 1715.639 | +0.0% |
| WM | 16 | equality | 0 | matches_checked | 90.833 | 108.952 | 109.983 | -91.8% |
| WM | 16 | equality | 0 | matches_unchecked | 81.284 | 106.461 | 108.813 | -92.7% |
| RWM | 16 | equality | 0 | access | 1096.027 | 1214.785 | 1266.970 | +0.0% |
| RWM | 16 | equality | 0 | matches_checked | 78.036 | 91.230 | 93.581 | -92.9% |
| RWM | 16 | equality | 0 | matches_unchecked | 87.256 | 136.478 | 205.540 | -92.0% |
| WM | 16 | equality | 1 | access | 1093.623 | 1306.769 | 1483.958 | +0.0% |
| WM | 16 | equality | 1 | matches_checked | 94.173 | 112.736 | 122.411 | -91.4% |
| WM | 16 | equality | 1 | matches_unchecked | 94.036 | 108.721 | 111.215 | -91.4% |
| RWM | 16 | equality | 1 | access | 1099.233 | 1579.865 | 1663.135 | +0.0% |
| RWM | 16 | equality | 1 | matches_checked | 97.444 | 133.496 | 158.938 | -91.1% |
| RWM | 16 | equality | 1 | matches_unchecked | 91.682 | 105.602 | 122.757 | -91.7% |
| WM | 16 | equality | 50 | access | 1118.624 | 1319.300 | 1409.616 | +0.0% |
| WM | 16 | equality | 50 | matches_checked | 514.469 | 631.796 | 643.617 | -54.0% |
| WM | 16 | equality | 50 | matches_unchecked | 542.498 | 649.261 | 721.735 | -51.5% |
| RWM | 16 | equality | 50 | access | 1067.808 | 1262.097 | 1437.340 | +0.0% |
| RWM | 16 | equality | 50 | matches_checked | 528.783 | 880.168 | 1018.158 | -50.5% |
| RWM | 16 | equality | 50 | matches_unchecked | 546.911 | 706.960 | 711.202 | -48.8% |
| WM | 16 | equality | 100 | access | 1089.340 | 1294.049 | 1319.462 | +0.0% |
| WM | 16 | equality | 100 | matches_checked | 991.752 | 1197.262 | 1236.286 | -9.0% |
| WM | 16 | equality | 100 | matches_unchecked | 961.612 | 1132.113 | 1189.707 | -11.7% |
| RWM | 16 | equality | 100 | access | 1070.420 | 1384.742 | 2078.471 | +0.0% |
| RWM | 16 | equality | 100 | matches_checked | 937.706 | 1060.613 | 1136.650 | -12.4% |
| RWM | 16 | equality | 100 | matches_unchecked | 955.436 | 1098.979 | 1192.897 | -10.7% |
| WM | 16 | range | 0.1 | access | 1103.462 | 1322.078 | 1396.213 | +0.0% |
| WM | 16 | range | 0.1 | range_unchecked | 72.327 | 85.652 | 87.213 | -93.4% |
| WM | 16 | range | 1 | access | 1072.604 | 1400.457 | 1616.921 | +0.0% |
| WM | 16 | range | 1 | range_unchecked | 68.315 | 80.578 | 81.394 | -93.6% |
| WM | 16 | range | 10 | access | 1060.017 | 1310.417 | 1333.690 | +0.0% |
| WM | 16 | range | 10 | range_unchecked | 66.457 | 90.955 | 101.968 | -93.7% |
| WM | 16 | range | 25 | access | 1043.106 | 1206.474 | 1218.392 | +0.0% |
| WM | 16 | range | 25 | range_unchecked | 44.305 | 65.597 | 71.592 | -95.8% |
| WM | 16 | range | 40 | access | 1126.877 | 1374.260 | 2028.334 | +0.0% |
| WM | 16 | range | 40 | range_unchecked | 72.583 | 96.174 | 106.972 | -93.6% |
| WM | 16 | range | 50 | access | 1050.479 | 1192.505 | 1231.741 | +0.0% |
| WM | 16 | range | 50 | range_unchecked | 19.326 | 30.777 | 31.580 | -98.2% |
| WM | 16 | range | 75 | access | 1044.811 | 1292.593 | 1371.558 | +0.0% |
| WM | 16 | range | 75 | range_unchecked | 43.520 | 54.329 | 107.632 | -95.8% |
| WM | 16 | range | 90 | access | 1056.857 | 1185.231 | 1302.408 | +0.0% |
| WM | 16 | range | 90 | range_unchecked | 68.817 | 81.258 | 83.999 | -93.5% |
| WM | 16 | range | 100 | access | 1086.811 | 1528.422 | 1719.301 | +0.0% |
| WM | 16 | range | 100 | range_unchecked | 7.566 | 8.430 | 9.218 | -99.3% |
| WM | 32 | equality | 0 | access | 2983.485 | 3135.210 | 3345.910 | +0.0% |
| WM | 32 | equality | 0 | matches_checked | 79.747 | 101.130 | 102.153 | -97.3% |
| WM | 32 | equality | 0 | matches_unchecked | 78.015 | 107.151 | 116.159 | -97.4% |
| RWM | 32 | equality | 0 | access | 2995.748 | 3207.146 | 4159.023 | +0.0% |
| RWM | 32 | equality | 0 | matches_checked | 82.397 | 105.223 | 109.287 | -97.2% |
| RWM | 32 | equality | 0 | matches_unchecked | 77.023 | 92.840 | 96.512 | -97.4% |
| WM | 32 | equality | 1 | access | 3031.902 | 3356.750 | 3662.308 | +0.0% |
| WM | 32 | equality | 1 | matches_checked | 118.341 | 138.203 | 138.797 | -96.1% |
| WM | 32 | equality | 1 | matches_unchecked | 114.946 | 151.807 | 163.985 | -96.2% |
| RWM | 32 | equality | 1 | access | 2982.345 | 3485.435 | 3535.354 | +0.0% |
| RWM | 32 | equality | 1 | matches_checked | 112.481 | 158.120 | 161.771 | -96.2% |
| RWM | 32 | equality | 1 | matches_unchecked | 115.493 | 133.685 | 133.740 | -96.1% |
| WM | 32 | equality | 50 | access | 2962.992 | 3225.428 | 3317.551 | +0.0% |
| WM | 32 | equality | 50 | matches_checked | 1437.895 | 2560.179 | 3197.405 | -51.5% |
| WM | 32 | equality | 50 | matches_unchecked | 1368.138 | 1551.915 | 1639.959 | -53.8% |
| RWM | 32 | equality | 50 | access | 3066.631 | 3649.819 | 3924.767 | +0.0% |
| RWM | 32 | equality | 50 | matches_checked | 1353.735 | 1512.711 | 1739.386 | -55.9% |
| RWM | 32 | equality | 50 | matches_unchecked | 1426.165 | 1877.182 | 2032.877 | -53.5% |
| WM | 32 | equality | 100 | access | 3011.214 | 3354.839 | 4190.147 | +0.0% |
| WM | 32 | equality | 100 | matches_checked | 2641.500 | 3068.443 | 3496.210 | -12.3% |
| WM | 32 | equality | 100 | matches_unchecked | 2620.758 | 2950.396 | 3601.365 | -13.0% |
| RWM | 32 | equality | 100 | access | 3031.364 | 3218.336 | 3300.660 | +0.0% |
| RWM | 32 | equality | 100 | matches_checked | 2712.027 | 3038.594 | 3349.795 | -10.5% |
| RWM | 32 | equality | 100 | matches_unchecked | 2774.471 | 3346.191 | 3602.510 | -8.5% |
| WM | 32 | range | 0.1 | access | 3267.766 | 3624.761 | 4229.569 | +0.0% |
| WM | 32 | range | 0.1 | range_unchecked | 80.525 | 109.903 | 116.403 | -97.5% |
| WM | 32 | range | 1 | access | 3382.228 | 3683.488 | 4229.176 | +0.0% |
| WM | 32 | range | 1 | range_unchecked | 82.219 | 100.992 | 104.257 | -97.6% |
| WM | 32 | range | 10 | access | 3364.226 | 4250.053 | 4289.484 | +0.0% |
| WM | 32 | range | 10 | range_unchecked | 76.754 | 91.618 | 91.643 | -97.7% |
| WM | 32 | range | 25 | access | 3246.070 | 3697.123 | 4269.239 | +0.0% |
| WM | 32 | range | 25 | range_unchecked | 46.047 | 53.951 | 55.481 | -98.6% |
| WM | 32 | range | 40 | access | 3107.676 | 3541.235 | 3702.527 | +0.0% |
| WM | 32 | range | 40 | range_unchecked | 70.811 | 83.765 | 95.982 | -97.7% |
| WM | 32 | range | 50 | access | 3060.341 | 3329.936 | 4037.622 | +0.0% |
| WM | 32 | range | 50 | range_unchecked | 19.361 | 21.789 | 22.258 | -99.4% |
| WM | 32 | range | 75 | access | 2995.722 | 3462.896 | 3514.128 | +0.0% |
| WM | 32 | range | 75 | range_unchecked | 42.466 | 52.966 | 54.000 | -98.6% |
| WM | 32 | range | 90 | access | 3011.787 | 3488.119 | 4038.905 | +0.0% |
| WM | 32 | range | 90 | range_unchecked | 70.671 | 94.656 | 99.638 | -97.7% |
| WM | 32 | range | 100 | access | 3030.413 | 3349.608 | 4051.532 | +0.0% |
| WM | 32 | range | 100 | range_unchecked | 7.496 | 7.661 | 8.212 | -99.8% |
| WM | 64 | equality | 0 | access | 8176.429 | 8647.796 | 8660.999 | +0.0% |
| WM | 64 | equality | 0 | matches_checked | 81.316 | 103.607 | 104.196 | -99.0% |
| WM | 64 | equality | 0 | matches_unchecked | 77.484 | 97.866 | 98.066 | -99.1% |
| RWM | 64 | equality | 0 | access | 8468.342 | 9068.111 | 9376.000 | +0.0% |
| RWM | 64 | equality | 0 | matches_checked | 73.264 | 88.910 | 93.291 | -99.1% |
| RWM | 64 | equality | 0 | matches_unchecked | 73.924 | 92.957 | 93.876 | -99.1% |
| WM | 64 | equality | 1 | access | 8297.943 | 8998.234 | 10024.861 | +0.0% |
| WM | 64 | equality | 1 | matches_checked | 206.390 | 248.448 | 251.960 | -97.5% |
| WM | 64 | equality | 1 | matches_unchecked | 186.829 | 198.486 | 203.346 | -97.7% |
| RWM | 64 | equality | 1 | access | 8646.651 | 9328.232 | 9674.068 | +0.0% |
| RWM | 64 | equality | 1 | matches_checked | 175.126 | 213.701 | 215.228 | -98.0% |
| RWM | 64 | equality | 1 | matches_unchecked | 168.267 | 201.679 | 214.104 | -98.1% |
| WM | 64 | equality | 50 | access | 8179.073 | 8924.756 | 9094.651 | +0.0% |
| WM | 64 | equality | 50 | matches_checked | 3700.154 | 3881.755 | 5044.120 | -54.8% |
| WM | 64 | equality | 50 | matches_unchecked | 3839.213 | 4013.596 | 4817.517 | -53.1% |
| RWM | 64 | equality | 50 | access | 8759.865 | 9532.728 | 9677.013 | +0.0% |
| RWM | 64 | equality | 50 | matches_checked | 3994.338 | 4465.268 | 4626.722 | -54.4% |
| RWM | 64 | equality | 50 | matches_unchecked | 3921.972 | 4282.868 | 4724.348 | -55.2% |
| WM | 64 | equality | 100 | access | 8692.774 | 9302.739 | 9608.169 | +0.0% |
| WM | 64 | equality | 100 | matches_checked | 8006.490 | 9056.788 | 9129.033 | -7.9% |
| WM | 64 | equality | 100 | matches_unchecked | 7477.805 | 8732.769 | 8767.308 | -14.0% |
| RWM | 64 | equality | 100 | access | 8496.799 | 9192.793 | 9324.501 | +0.0% |
| RWM | 64 | equality | 100 | matches_checked | 8001.529 | 12417.456 | 13199.920 | -5.8% |
| RWM | 64 | equality | 100 | matches_unchecked | 7825.218 | 11139.085 | 11465.804 | -7.9% |
| WM | 64 | range | 0.1 | access | 8307.550 | 9112.777 | 9845.135 | +0.0% |
| WM | 64 | range | 0.1 | range_unchecked | 68.126 | 75.726 | 83.893 | -99.2% |
| WM | 64 | range | 1 | access | 9214.027 | 10382.285 | 10513.858 | +0.0% |
| WM | 64 | range | 1 | range_unchecked | 79.650 | 89.288 | 89.485 | -99.1% |
| WM | 64 | range | 10 | access | 8761.227 | 9382.271 | 9577.373 | +0.0% |
| WM | 64 | range | 10 | range_unchecked | 76.640 | 92.868 | 103.070 | -99.1% |
| WM | 64 | range | 25 | access | 8034.009 | 8838.046 | 9233.892 | +0.0% |
| WM | 64 | range | 25 | range_unchecked | 65.027 | 97.973 | 99.857 | -99.2% |
| WM | 64 | range | 40 | access | 8033.027 | 9228.821 | 9295.254 | +0.0% |
| WM | 64 | range | 40 | range_unchecked | 64.127 | 70.617 | 70.871 | -99.2% |
| WM | 64 | range | 50 | access | 8080.439 | 13240.730 | 16489.882 | +0.0% |
| WM | 64 | range | 50 | range_unchecked | 73.335 | 89.913 | 109.134 | -99.1% |
| WM | 64 | range | 75 | access | 8550.918 | 9156.628 | 9376.562 | +0.0% |
| WM | 64 | range | 75 | range_unchecked | 71.054 | 74.594 | 87.156 | -99.2% |
| WM | 64 | range | 90 | access | 8372.004 | 9117.198 | 9358.632 | +0.0% |
| WM | 64 | range | 90 | range_unchecked | 75.436 | 92.814 | 106.086 | -99.1% |
| WM | 64 | range | 100 | access | 8959.920 | 9667.627 | 9725.987 | +0.0% |
| WM | 64 | range | 100 | range_unchecked | 9.022 | 12.169 | 12.625 | -99.9% |

## Early-exit / pruning statistics

Statistics use the unchecked predicate workload. `<=2 levels` is cumulative.

| Matrix | Bits | Predicate | Workload (%) | Avg levels | Level 1 | <=2 levels | Full | Disjoint | Contained |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| WM | 8 | equality | 0 | 1.996 | 49.84% | 74.79% | 0.78% | 0.00% | 0.00% |
| RWM | 8 | equality | 0 | 1.972 | 50.19% | 75.20% | 0.39% | 0.00% | 0.00% |
| WM | 8 | equality | 1 | 2.059 | 49.37% | 74.11% | 1.81% | 0.00% | 0.00% |
| RWM | 8 | equality | 1 | 2.028 | 49.87% | 74.61% | 1.42% | 0.00% | 0.00% |
| WM | 8 | equality | 50 | 5.001 | 24.83% | 37.42% | 50.42% | 0.00% | 0.00% |
| RWM | 8 | equality | 50 | 4.981 | 25.30% | 37.79% | 50.20% | 0.00% | 0.00% |
| WM | 8 | equality | 100 | 8.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| RWM | 8 | equality | 100 | 8.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| WM | 8 | range | 0.1 | 1.997 | 49.91% | 75.02% | 0.77% | 99.62% | 0.38% |
| WM | 8 | range | 1 | 1.998 | 49.91% | 75.02% | 0.86% | 98.80% | 1.20% |
| WM | 8 | range | 10 | 1.986 | 49.91% | 75.02% | 0.00% | 89.83% | 10.16% |
| WM | 8 | range | 25 | 1.501 | 49.91% | 100.00% | 0.00% | 75.02% | 24.98% |
| WM | 8 | range | 40 | 2.481 | 49.91% | 49.91% | 0.79% | 60.43% | 39.57% |
| WM | 8 | range | 50 | 1.000 | 100.00% | 100.00% | 0.00% | 49.91% | 50.09% |
| WM | 8 | range | 75 | 1.499 | 50.09% | 100.00% | 0.00% | 25.08% | 74.92% |
| WM | 8 | range | 90 | 1.986 | 50.09% | 74.92% | 0.00% | 10.25% | 89.75% |
| WM | 8 | range | 100 | 1.000 | 100.00% | 100.00% | 0.00% | 0.00% | 100.00% |
| WM | 16 | equality | 0 | 2.010 | 49.68% | 74.74% | 0.00% | 0.00% | 0.00% |
| RWM | 16 | equality | 0 | 1.998 | 49.86% | 74.95% | 0.00% | 0.00% | 0.00% |
| WM | 16 | equality | 1 | 2.136 | 49.51% | 74.28% | 1.00% | 0.00% | 0.00% |
| RWM | 16 | equality | 1 | 2.143 | 49.50% | 74.16% | 1.00% | 0.00% | 0.00% |
| WM | 16 | equality | 50 | 8.998 | 25.05% | 37.51% | 50.00% | 0.00% | 0.00% |
| RWM | 16 | equality | 50 | 9.003 | 24.96% | 37.25% | 50.00% | 0.00% | 0.00% |
| WM | 16 | equality | 100 | 16.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| RWM | 16 | equality | 100 | 16.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| WM | 16 | range | 0.1 | 2.007 | 49.95% | 74.93% | 0.00% | 99.89% | 0.11% |
| WM | 16 | range | 1 | 2.006 | 49.95% | 74.93% | 0.00% | 98.93% | 1.07% |
| WM | 16 | range | 10 | 2.005 | 49.95% | 74.93% | 0.00% | 89.84% | 10.16% |
| WM | 16 | range | 25 | 1.501 | 49.95% | 100.00% | 0.00% | 74.93% | 25.07% |
| WM | 16 | range | 40 | 1.999 | 49.95% | 75.02% | 0.00% | 59.99% | 40.01% |
| WM | 16 | range | 50 | 1.000 | 100.00% | 100.00% | 0.00% | 49.95% | 50.05% |
| WM | 16 | range | 75 | 1.499 | 50.05% | 100.00% | 0.00% | 25.03% | 74.97% |
| WM | 16 | range | 90 | 1.999 | 50.05% | 74.97% | 0.00% | 9.92% | 90.08% |
| WM | 16 | range | 100 | 1.000 | 100.00% | 100.00% | 0.00% | 0.00% | 100.00% |
| WM | 32 | equality | 0 | 1.996 | 50.08% | 74.99% | 0.00% | 0.00% | 0.00% |
| RWM | 32 | equality | 0 | 2.003 | 50.12% | 74.95% | 0.00% | 0.00% | 0.00% |
| WM | 32 | equality | 1 | 2.292 | 49.95% | 74.48% | 1.00% | 0.00% | 0.00% |
| RWM | 32 | equality | 1 | 2.307 | 49.49% | 74.01% | 1.00% | 0.00% | 0.00% |
| WM | 32 | equality | 50 | 17.000 | 25.09% | 37.51% | 50.00% | 0.00% | 0.00% |
| RWM | 32 | equality | 50 | 17.001 | 24.85% | 37.57% | 50.00% | 0.00% | 0.00% |
| WM | 32 | equality | 100 | 32.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| RWM | 32 | equality | 100 | 32.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| WM | 32 | range | 0.1 | 1.999 | 50.10% | 75.01% | 0.00% | 99.89% | 0.11% |
| WM | 32 | range | 1 | 1.998 | 50.10% | 75.01% | 0.00% | 98.95% | 1.05% |
| WM | 32 | range | 10 | 1.995 | 50.10% | 75.01% | 0.00% | 90.08% | 9.93% |
| WM | 32 | range | 25 | 1.499 | 50.10% | 100.00% | 0.00% | 75.01% | 24.99% |
| WM | 32 | range | 40 | 1.999 | 50.10% | 75.09% | 0.00% | 60.11% | 39.89% |
| WM | 32 | range | 50 | 1.000 | 100.00% | 100.00% | 0.00% | 50.10% | 49.90% |
| WM | 32 | range | 75 | 1.501 | 49.90% | 100.00% | 0.00% | 25.04% | 74.96% |
| WM | 32 | range | 90 | 2.001 | 49.90% | 74.96% | 0.00% | 9.86% | 90.14% |
| WM | 32 | range | 100 | 1.000 | 100.00% | 100.00% | 0.00% | 0.00% | 100.00% |
| WM | 64 | equality | 0 | 2.003 | 49.96% | 74.93% | 0.00% | 0.00% | 0.00% |
| RWM | 64 | equality | 0 | 1.994 | 50.19% | 75.16% | 0.00% | 0.00% | 0.00% |
| WM | 64 | equality | 1 | 2.621 | 49.44% | 74.19% | 1.00% | 0.00% | 0.00% |
| RWM | 64 | equality | 1 | 2.623 | 49.34% | 74.13% | 1.00% | 0.00% | 0.00% |
| WM | 64 | equality | 50 | 32.993 | 25.29% | 37.59% | 50.00% | 0.00% | 0.00% |
| RWM | 64 | equality | 50 | 33.003 | 24.91% | 37.48% | 50.00% | 0.00% | 0.00% |
| WM | 64 | equality | 100 | 64.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| RWM | 64 | equality | 100 | 64.000 | 0.00% | 0.00% | 100.00% | 0.00% | 0.00% |
| WM | 64 | range | 0.1 | 2.007 | 49.79% | 74.93% | 0.00% | 99.89% | 0.11% |
| WM | 64 | range | 1 | 2.007 | 49.79% | 74.93% | 0.00% | 98.95% | 1.05% |
| WM | 64 | range | 10 | 2.006 | 49.79% | 74.93% | 0.00% | 89.94% | 10.06% |
| WM | 64 | range | 25 | 2.007 | 49.79% | 74.86% | 0.00% | 74.93% | 25.07% |
| WM | 64 | range | 40 | 2.007 | 49.79% | 74.86% | 0.00% | 59.86% | 40.14% |
| WM | 64 | range | 50 | 1.999 | 50.21% | 75.15% | 0.00% | 49.79% | 50.21% |
| WM | 64 | range | 75 | 1.996 | 50.21% | 75.06% | 0.00% | 24.94% | 75.06% |
| WM | 64 | range | 90 | 1.999 | 50.21% | 75.06% | 0.00% | 9.97% | 90.03% |
| WM | 64 | range | 100 | 1.000 | 100.00% | 100.00% | 0.00% | 0.00% | 100.00% |

## Interpretation

- Equality `matchesAtUnchecked` changed p50 by -99.1% to -7.9% versus `access`; no measured hit-rate/bit-width case crossed into a regression. WM and RWM are directly comparable because they share positions and independently generated targets.
- Range `valueInRangeAtUnchecked` changed p50 by -99.9% to -83.9%; no measured selectivity crossed into a regression.
- The ShikiDB-like 8-bit inclusive range `25..125` (uniform selectivity about 39.45%) measured 95.731 ns/probe versus 436.321 ns/probe for `access`, so this workload should adopt the predicate API on this environment.
- Equality benefit narrows as hit rate approaches 100% because successful probes require full traversal. Range latency follows prefix shape as well as selectivity, so callers should re-run this benchmark for materially different distributions.
