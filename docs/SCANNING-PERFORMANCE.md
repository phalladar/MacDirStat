# Scanner performance validation

The scanner uses `getattrlistbulk` to fetch names and regular-file metadata in
batches. Directories still use `fstatat` so mount/firmlink identity and directory
sizes match POSIX traversal. Unsupported filesystems retain a POSIX fallback on
a fresh directory descriptor. All enumeration stays inside the synchronous,
thread-scoped dataless-materialization opt-out.
User-requested scans use user-initiated task priority because the treemap is
unavailable until the scan completes; the four-directory limit remains in place.
The per-directory scratch buffer is 16 KiB rather than 128 KiB; wide directories
use multiple batches. This reduces scratch allocation eightfold without omitting
entries.

## Reproduce

```sh
MACDIRSTAT_BENCHMARK_PATH=/path/to/stable/folder swift test -c release \
  --filter compareDirectoryEnumerationPerformance --no-parallel
```

The benchmark alternates POSIX, bulk, bulk, POSIX with four directory workers.
Each run builds the tree, computes aggregates and sorts it. It checks matching
file/folder counts, logical/allocated sizes, cloud-only files and incomplete
folders. File contents are not read. The ordinary suite separately compares
every entry's metadata, including sparse files, Unicode names and resource forks.
Live cloud and performance tests are opt-in; CI does not depend on cloud accounts
or hardware-specific timing thresholds.

## Measurements on 6 October 2026

| Tree | Files | Folders | POSIX runs | Bulk runs |
| --- | ---: | ---: | --- | --- |
| Local dependency tree | 13,286 | 1,534 | 5.626 s, 2.161 s | 1.161 s, 2.144 s |
| Live CloudStorage tree | 170,791 | 25,421 | 78.668 s, 56.245 s | 17.001 s, 17.086 s |
| Xcode Developer directory | 109,725 | 22,755 | 78.575 s, 33.925 s | 19.026 s, 11.925 s |

These initial comparisons used utility task priority. All four runs for each
tree produced matching totals. The cloud tree measured
515,245,550,178 logical bytes and 46,763,343,872 allocated bytes, with 141,054
cloud-only files and 887 incomplete directories. A separate selected real
cloud-only directory retained its dataless flag and unchanged allocated blocks.

The later POSIX run was still about 3.3 times slower than the slower bulk run on
the cloud tree, and 2.8 times slower on the Xcode tree. The small dependency tree
showed substantial timing variation, including a nearly equal later pair. Cache
warmth, filesystem type and other machine activity affect results. These are
measurements of these trees, not a speed guarantee for every drive or whole-Mac
scan. Allocated totals are not unique physical storage or guaranteed reclaimable
space on APFS.

A separate whole-Mac utility-priority integration run was stopped after more
than ten minutes without completing. Its sample remained dominated by filesystem
I/O, and it produced no final totals. It is not a successful full-disk benchmark
or evidence of a whole-Mac speedup.

With user-initiated priority, another four alternating cloud runs also matched
all totals: POSIX 25.745/14.694 seconds and bulk 15.073/13.007 seconds. A standalone
scanner-only comparison of 128/16 KiB buffers produced matching cloud totals at
8.842/9.950 and 8.817/10.143 seconds respectively, while a separate root scan
was active. Those noisy timings do not demonstrate a buffer speedup; the smaller
buffer is a memory-allocation improvement. Whole-Mac timing remains unverified.
A bounded standalone 16 KiB root scan reached 5,476,856 files and
985,882,173,440 progress bytes at 233.891 seconds, then stopped at its
240-second deadline without a completed tree. Those are partial progress values,
not full-disk totals or a successful integration benchmark.

Apple's [user-initiated QoS guidance](https://developer.apple.com/documentation/dispatch/dispatchqos/userInitiated)
describes work whose results are needed to continue using the app.

Apple references: [getattrlistbulk manual](https://github.com/apple/darwin-xnu/blob/main/bsd/man/man2/getattrlistbulk.2),
[dataless-file guidance](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files).
