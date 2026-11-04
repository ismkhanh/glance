# Glance agent evals

Model `muse-spark-1.3` · live run of 2026-11-04 · 3 trials per case.
How they work and how to run them: [evals/README.md](README.md).

## The agent: spoken commands on a Figma document

| Measure | Result |
| --- | --- |
| Runs that did exactly what was asked | 100% (123/123) |
| Cases right in every trial (pass^3) | 100% (41/41) |
| Runs that changed anything outside what was asked | 0 of 123 |
| Safety cases (injected instructions, out of scope, delete) | 100% (15/15) |
| Asked a question when the words left it open | 100% (3/3) |
| Asked a question when it did not need to | 1% (1/117) |
| Runs where the reviewer sent the work back | 6 of 123 |
| Tool calls that failed | 3 of 160, of which 3 were the scope guard refusing a layer outside the one pointed at |
| Muse calls per task (worker + reviewer) | 2.4 |
| Muse time per command | median 5.6 s, p95 16.3 s |
| Tokens per command | 4,493 |

| Category | Cases | Runs passed | Right every trial |
| --- | --- | --- | --- |
| color | 6 | 100% (18/18) | 6/6 |
| text | 5 | 100% (15/15) | 5/5 |
| layout | 5 | 100% (15/15) | 5/5 |
| scroll | 3 | 100% (9/9) | 3/3 |
| ask | 1 | 100% (3/3) | 1/1 |
| image | 1 | 100% (3/3) | 1/1 |
| multi | 3 | 100% (9/9) | 3/3 |
| target | 1 | 100% (3/3) | 1/1 |
| safety | 5 | 100% (15/15) | 5/5 |
| speech | 3 | 100% (9/9) | 3/3 |
| hard | 8 | 100% (24/24) | 8/8 |

## The reviewer: is a finished change right?

20 labelled changes (right or wrong for the words), 3 trials each. A wrong change let through is the costly mistake: the task panel would say "✓ Checked".

| Judge | Correct | Wrong changes let through | Right changes sent back |
| --- | --- | --- | --- |
| Plain rules only | 70% (42/60) | 18 of 30 | 0 of 30 |
| Muse only | 100% (60/60) | 0 of 30 | 0 of 30 |
| Glance (rules, then Muse) | 100% (60/60) | 0 of 30 | 0 of 30 |

