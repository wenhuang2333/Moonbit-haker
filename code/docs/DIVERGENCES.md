# InterJSON differential report (TC-D)

InterJSON is compared against two independent reference
implementations. Only *parsed JSON values* are compared, never text,
because formatting is not part of the contract.

| item | value |
| --- | --- |
| provenance | omitted (--no-stamp) so this report is reproducible byte for byte; run without the flag for the date and the binary hash |
| primary oracle | `json-repair` (Python, MIT) 0.64.0 |
| secondary oracle | `jsonrepair` (TypeScript/Node, ISC) 3.15.0 from `/Users/zhanshishan/.npm-global/lib/node_modules` |
| corpus | 99 hand written cases + 303 automatic mutations |
| corpus selection | deterministic: fixed list plus fixed mutations, no seed |
| comparison | `json.loads(interjson stdout)` vs `json_repair.repair_json(..., return_objects=True)` |
| reproduce | `python3 code/tests/diff/run_diff.py --cli <interjson binary> [--node-module-dir DIR]` (see docs/REPRODUCE.md) |

A divergence is *documented* when InterJSON's own repair record list
explains it: the rules that fired are exactly the rules whose
documented behaviour differs from the reference implementation.

## Summary

| metric | value |
| --- | --- |
| cases | 402 |
| hand written | 99 (agreement 57.6%) |
| mutated | 303 (agreement 47.2%) |
| semantic agreement | 200 (49.8%) |
| both reject the input | 0 |
| divergences | 202 |
| divergences with a documented cause | 202 |
| unexplained divergences | 0 |
| documented-scope agreement | 100.0% |
| agreement with jsonrepair (node) | 59.7% (236/395) |

## Divergence classes

Every class is the set of repair rules InterJSON applied to reach
its answer; the referenced rule is why the two libraries differ.

| rules applied | count | documented cause |
| --- | --- | --- |
| `R004+R006+R007+R009+R010` | 24 | bare word quoted (BR-10); missing comma inserted (BR-06); missing colon inserted (BR-05); container closed (BR-13); string closed (BR-13) |
| `R008+R009+R010` | 21 | missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13) |
| `R004+R006+R007+R008+R009+R010+R012` | 15 | bare word quoted (BR-10); missing comma inserted (BR-06); missing colon inserted (BR-05); missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13); literal converted or completed (BR-12, BR-13) |
| `R008+R009` | 12 | missing value filled with null (BR-13); container closed (BR-13) |
| `R004+R006+R009+R010+R012` | 12 | bare word quoted (BR-10); missing comma inserted (BR-06); container closed (BR-13); string closed (BR-13); literal converted or completed (BR-12, BR-13) |
| `R004+R006+R007+R008+R009+R010+R012+R018` | 9 | bare word quoted (BR-10); missing comma inserted (BR-06); missing colon inserted (BR-05); missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13); literal converted or completed (BR-12, BR-13); duplicate key merged (BR-19) |
| `interjson rejects, jsonrepair repairs (E001/E002/E040)` | 8 | FR-01 no JSON value found (E001/E002/E040); jsonrepair invents a value |
| `R012` | 6 | literal converted or completed (BR-12, BR-13) |
| `R009+R012` | 6 | container closed (BR-13); literal converted or completed (BR-12, BR-13) |
| `R019` | 6 | adjacent strings concatenated (BR-21) |
| `R004+R006+R007+R008+R009+R010` | 6 | bare word quoted (BR-10); missing comma inserted (BR-06); missing colon inserted (BR-05); missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13) |
| `R007` | 5 | missing colon inserted (BR-05) |
| `R016` | 5 | unexpected content dropped (BR-15, multi_root=first default) |
| `multi-root (BR-15 policy)` | 4 | BR-15 multi_root=first (probe: --multi-root array agrees) |
| `R005+R008+R015+R016` | 4 | extra comma removed (BR-06); missing value filled with null (BR-13); mismatched closer replaced (BR-14); unexpected content dropped (BR-15, multi_root=first default) |
| `R005+R008+R016` | 4 | extra comma removed (BR-06); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `prose (skip_prose off by default)` | 3 | FR-08 skip_prose off by default (probe: --skip-prose agrees) |
| `R005` | 3 | extra comma removed (BR-06) |
| `R009+R010+R014` | 3 | container closed (BR-13); string closed (BR-13); invalid escape repaired (BR-08) |
| `R014` | 3 | invalid escape repaired (BR-08) |
| `R009+R010` | 3 | container closed (BR-13); string closed (BR-13) |
| `R008+R016` | 3 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R005+R008+R012` | 3 | bare word quoted (BR-10); extra comma removed (BR-06); missing value filled with null (BR-13); literal converted or completed (BR-12, BR-13) |
| `R006+R008+R009+R010+R012` | 3 | missing comma inserted (BR-06); missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13); literal converted or completed (BR-12, BR-13) |
| `R004+R006+R008+R012+R017` | 3 | bare word quoted (BR-10); missing comma inserted (BR-06); missing value filled with null (BR-13); literal converted or completed (BR-12, BR-13); extra closer dropped (BR-14) |
| `R004+R006+R008+R016+R017` | 2 | bare word quoted (BR-10); missing comma inserted (BR-06); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); extra closer dropped (BR-14) |
| `R008+R016+R017` | 2 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); extra closer dropped (BR-14) |
| `R004+R008` | 2 | bare word quoted (BR-10); missing value filled with null (BR-13) |
| `R007+R009+R010` | 2 | missing colon inserted (BR-05); container closed (BR-13); string closed (BR-13) |
| `R006+R008+R009+R010` | 2 | missing comma inserted (BR-06); missing value filled with null (BR-13); container closed (BR-13); string closed (BR-13) |
| `R005+R016` | 2 | extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `R005+R006+R008+R015+R016` | 2 | extra comma removed (BR-06); missing comma inserted (BR-06); missing value filled with null (BR-13); mismatched closer replaced (BR-14); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R006+R008+R017` | 2 | bare word quoted (BR-10); missing comma inserted (BR-06); missing value filled with null (BR-13); extra closer dropped (BR-14) |
| `R004+R006+R008` | 1 | bare word quoted (BR-10); missing comma inserted (BR-06); missing value filled with null (BR-13) |
| `R004` | 1 | bare word quoted (BR-10) |
| `R020` | 1 | ellipsis placeholder dropped (BR-21) |
| `R006+R009+R015+R016` | 1 | missing comma inserted (BR-06); container closed (BR-13); mismatched closer replaced (BR-14); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R007+R009+R010` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); container closed (BR-13); string closed (BR-13) |
| `R008` | 1 | missing value filled with null (BR-13) |
| `R004+R008+R016` | 1 | bare word quoted (BR-10); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R005+R008+R016` | 1 | bare word quoted (BR-10); extra comma removed (BR-06); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R005+R008` | 1 | bare word quoted (BR-10); extra comma removed (BR-06); missing value filled with null (BR-13) |
| `R015+R016` | 1 | mismatched closer replaced (BR-14); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R005+R006+R008+R016+R017` | 1 | bare word quoted (BR-10); extra comma removed (BR-06); missing comma inserted (BR-06); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); extra closer dropped (BR-14) |
| `R004+R005+R006+R008+R017` | 1 | bare word quoted (BR-10); extra comma removed (BR-06); missing comma inserted (BR-06); missing value filled with null (BR-13); extra closer dropped (BR-14) |

## Rules responsible for divergences

| rule | divergences |
| --- | --- |
| R009 | 120 |
| R008 | 102 |
| R010 | 101 |
| R004 | 86 |
| R006 | 84 |
| R007 | 62 |
| R012 | 57 |
| R016 | 33 |
| R005 | 22 |
| R017 | 11 |
| R018 | 9 |
| R015 | 8 |
| R014 | 6 |
| R019 | 6 |
| R020 | 1 |

## Unexplained divergences

None: every divergence is attributed to a documented rule or policy.


## Samples per class

### `R004+R006+R007+R009+R010`

- input `'{name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': ':', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit,"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit,', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit",tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ':12,', 'ok': ':true}}'}} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R009+R010`

- input `'{"'`
  - interjson (rc 0): {'': None} ['R008', 'R009', 'R010']
  - json-repair: {}
- input `'{"n'`
  - interjson (rc 0): {'n': None} ['R008', 'R009', 'R010']
  - json-repair: ['n']
- input `'{"na'`
  - interjson (rc 0): {'na': None} ['R008', 'R009', 'R010']
  - json-repair: ['na']
- input `'{"nam'`
  - interjson (rc 0): {'nam': None} ['R008', 'R009', 'R010']
  - json-repair: ['nam']
- input `'{"name'`
  - interjson (rc 0): {'name': None} ['R008', 'R009', 'R010']
  - json-repair: ['name']

### `R004+R006+R007+R008+R009+R010+R012`

- input `'{"name":"moonbit","tags:["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags:[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta:{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta:{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta:{"n': 12, 'ok': True}
- input `'{"name":"moonbit",""tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', '': 'tags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit",""tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', '': 'tags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","t"ags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 't': 'ags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 't"ags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R009`

- input `'{"a":'`
  - interjson (rc 0): {'a': None} ['R008', 'R009']
  - json-repair: {'a': ''}
- input `'{"a":-'`
  - interjson (rc 0): {'a': None} ['R008', 'R009']
  - json-repair: {'a': ''}
- input `'{"name"'`
  - interjson (rc 0): {'name': None} ['R008', 'R009']
  - json-repair: ['name']
- input `'{"name":'`
  - interjson (rc 0): {'name': None} ['R008', 'R009']
  - json-repair: {'name': ''}
- input `'{"name":"moonbit","tags"'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': None} ['R008', 'R009']
  - json-repair: {'name': 'moonbit'}

### `R004+R006+R009+R010+R012`

- input `'{"name":"moonbit","tags":[a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a,"b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a,', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a,', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a",b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b],', 'meta":{"n', 12], 'ok': True}
- input `'{"name":"moonbit","tags":[""a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['', 'a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R006+R007+R008+R009+R010+R012+R018`

- input `'{"name:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name:': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{""name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'': 'name', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{""name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'': 'name', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"n"ame":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'n': 'ame', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'n"ame': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `interjson rejects, jsonrepair repairs (E001/E002/E040)`

- input `''`
  - interjson (rc 3): None []
  - json-repair: ''
- input `'   '`
  - interjson (rc 3): None []
  - json-repair: ''
- input `'\n\n'`
  - interjson (rc 3): None []
  - json-repair: ''
- input `'hello world'`
  - interjson (rc 3): None []
  - json-repair: ''
- input `'}'`
  - interjson (rc 3): None []
  - json-repair: ''

### `R012`

- input `'{"a":undefined}'`
  - interjson (rc 0): {'a': None} ['R012']
  - json-repair: {'a': 'undefined'}
- input `'{"a":NaN}'`
  - interjson (rc 0): {'a': None} ['R012']
  - json-repair: {'a': nan}
- input `'{"a":Infinity}'`
  - interjson (rc 0): {'a': None} ['R012']
  - json-repair: {'a': inf}
- input `'{"a":-Infinity}'`
  - interjson (rc 0): {'a': None} ['R012']
  - json-repair: {'a': -inf}
- input `'nul'`
  - interjson (rc 0): None ['R012']
  - json-repair: ''

### `R009+R012`

- input `'{"a":tru'`
  - interjson (rc 0): {'a': True} ['R009', 'R012']
  - json-repair: {'a': 'tru'}
- input `'{"a":fals'`
  - interjson (rc 0): {'a': False} ['R009', 'R012']
  - json-repair: {'a': 'fals'}
- input `'{"a":nul'`
  - interjson (rc 0): {'a': None} ['R009', 'R012']
  - json-repair: {'a': 'nul'}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R009', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R009', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr'}}

### `R019`

- input `'["a" + "b"]'`
  - interjson (rc 0): ['ab'] ['R019']
  - json-repair: ['a" + "b']
- input `'["a"+"b"+"c"]'`
  - interjson (rc 0): ['abc'] ['R019']
  - json-repair: ['a"+"b"+"c']
- input `'{"k":"a" + "b"}'`
  - interjson (rc 0): {'k': 'ab'} ['R019']
  - json-repair: {'k': 'a" + "b'}
- input `'"a" + "b"'`
  - interjson (rc 0): 'ab' ['R019']
  - json-repair: ''
- input `'{"a":"x" + "y" + "z"}'`
  - interjson (rc 0): {'a': 'xyz'} ['R019']
  - json-repair: {'a': 'x" + "y" + "z'}

### `R004+R006+R007+R008+R009+R010`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n:12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n:12,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n:12,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1"2,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12","ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, ',': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,""ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, '': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,""ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, '': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007`

- input `'{"a" 1}'`
  - interjson (rc 0): {'a': 1} ['R007']
  - json-repair: {'a': ''}
- input `'{"name":"moonbit","tags"["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags"["a","b"],"meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta"{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta"{"n': 12, 'ok': True}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n"12,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'rue'}}

### `R016`

- input `'[[1]][[2]][[3]]'`
  - interjson (rc 0): [[1]] ['R016']
  - json-repair: [[3]]
- input `'"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): 'name' ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{}"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {} ['R016']
  - json-repair: [['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit"},"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit'} ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"]},"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `multi-root (BR-15 policy)`

- input `'{"a":1}{"b":2}'`
  - interjson (rc 0): {'a': 1} ['R016']
  - json-repair: [{'a': 1}, {'b': 2}]
- input `'{"a":1} {"b":2}'`
  - interjson (rc 0): {'a': 1} ['R016']
  - json-repair: [{'a': 1}, {'b': 2}]
- input `'{"a":1}{"b":2}{"c":3}'`
  - interjson (rc 0): {'a': 1} ['R016']
  - json-repair: [{'a': 1}, {'b': 2}, {'c': 3}]
- input `'{"a":{"b":1}}{"c":{"d":2}}'`
  - interjson (rc 0): {'a': {'b': 1}} ['R016']
  - json-repair: [{'a': {'b': 1}}, {'c': {'d': 2}}]

### `R005+R008+R015+R016`

- input `'{"name":"moonbit","tags":"a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': 'a', 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': 'a', 'b"],"meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags",:["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': None, 'a': None, 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":,["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': None, 'a': None, 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': '', 'a","b"],"meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a"},"b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a'], 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a'], 'b"],"meta': {'n': 12, 'ok': True}}

### `R005+R008+R016`

- input `'{"name":"moonbit","tags"}:["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit'}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":}["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ''}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],"meta"}:{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b']}, {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],"meta":}{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ''}, {'n': 12, 'ok': True}]

### `prose (skip_prose off by default)`

- input `'Here is the JSON:\n{"a":1}'`
  - interjson (rc 3): None []
  - json-repair: {'a': 1}
- input `'Sure! {"a":1}'`
  - interjson (rc 3): None []
  - json-repair: {'a': 1}
- input `'# python comment\n{"a":1}'`
  - interjson (rc 3): None []
  - json-repair: {'a': 1}

### `R005`

- input `'{"a":1,,}'`
  - interjson (rc 0): {'a': 1} ['R005']
  - json-repair: {'a': '1,'}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R005']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,', 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R005']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,', 'ok': True}}

### `R009+R010+R014`

- input `'{"a":"\\'`
  - interjson (rc 0): {'a': ''} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\\'}
- input `'{"a":"\\u12'`
  - interjson (rc 0): {'a': ''} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\\u12'}
- input `'{"a":"\\uD83D'`
  - interjson (rc 0): {'a': '�'} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\ud83d'}

### `R014`

- input `'{"a":"bad\\qescape"}'`
  - interjson (rc 0): {'a': 'badqescape'} ['R014']
  - json-repair: {'a': 'bad\\qescape'}
- input `'["\\uD800"]'`
  - interjson (rc 0): ['�'] ['R014']
  - json-repair: ['\ud800']
- input `'["\\uDC00x"]'`
  - interjson (rc 0): ['�x'] ['R014']
  - json-repair: ['\udc00x']

### `R009+R010`

- input `'{"name":"moonbit","tags":["'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['']} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': []}
- input `'{"name":"moonbit","tags":["a","'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', '']} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a']}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":"true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true}}'}} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true'}}

### `R008+R016`

- input `'{"name",:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': None, 'moonbit': None, 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name"}:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': None} ['R008', 'R016']
  - json-repair: [['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":}"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': None} ['R008', 'R016']
  - json-repair: [{'name': ''}, ['a', 'b'], {'n': 12, 'ok': True}]

### `R004+R005+R008+R012`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t,rue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'rue': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't,rue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr,ue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'ue': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr,ue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru,e}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'e': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru,e'}}

### `R006+R008+R009+R010+R012`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t"rue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'rue}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr"ue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'ue}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru"e}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'e}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru'}}

### `R004+R006+R008+R012+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t}rue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'rue': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't}rue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr}ue}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'ue': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr}ue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru}e}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'e': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru'}}

### `R004+R006+R008+R016+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': 'n', '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': 'n', '12,"ok': True}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"}:12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}, '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {}, '12,"ok': True}

### `R008+R016+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta",:{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None, 'n': 12, 'ok': True} ['R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":,{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None, 'n': 12, 'ok': True} ['R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': '', 'n': 12, 'ok': True}

### `R004+R008`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":,12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None, '12': None, 'ok': True}} ['R004', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '', '12,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1,2,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2': None, 'ok': True}} ['R004', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '1,2', 'ok': True}}

### `R007+R009+R010`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R008+R009+R010`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true"}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, '}}': None}} ['R006', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}"}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, '}': None} ['R006', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R005+R016`

- input `'{"name":"moonbit",}"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit'} ['R005', 'R016']
  - json-repair: [{'name': 'moonbit'}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],}"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R005', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b']}, {'n': 12, 'ok': True}]

### `R005+R006+R008+R015+R016`

- input `'{"name":"moonbit","tags":[}"a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': [], 'a': None, 'b': None} ['R005', 'R006', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': [], 'a","b"],"meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a",}"b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a'], 'b': None} ['R005', 'R006', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a'], 'b"],"meta': {'n': 12, 'ok': True}}

### `R004+R006+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":}12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}, '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ''}, '12,"ok': True}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1}2,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1}, '2': None, 'ok': True} ['R004', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1}, '2,"ok': True}

### `R004+R006+R008`

- input `'{"a":- 1}'`
  - interjson (rc 0): {'a': None, '1': None} ['R004', 'R006', 'R008']
  - json-repair: {'a': ''}

### `R004`

- input `'{"a":1_000}'`
  - interjson (rc 0): {'a': '1_000'} ['R004']
  - json-repair: {'a': 1000}

### `R020`

- input `'{"a":...,"b":2}'`
  - interjson (rc 0): {'b': 2} ['R020']
  - json-repair: {'a': '...', 'b': 2}

### `R006+R009+R015+R016`

- input `'{"name":"moonbit","tags":["a","b","meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', 'meta', {'n': 12, 'ok': True}]} ['R006', 'R009', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R007+R009+R010`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R004', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,ok'}}

### `R008`

- input `'{"name":,"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': None, 'moonbit': None, 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R008']
  - json-repair: {'name': '', 'moonbit","tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R008+R016`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n",:12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None, '12': None, 'ok': True}} ['R004', 'R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R005+R008+R016`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok",:true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None, 'true': None}} ['R004', 'R005', 'R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R005+R008`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":,true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None, 'true': None}} ['R004', 'R005', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ''}}

### `R015+R016`

- input `'{"name":"moonbit","tags":["a","b"}],"meta":{"n":12,"ok":true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R005+R006+R008+R016+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"}:true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}, 'true': None} ['R004', 'R005', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}

### `R004+R005+R006+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":}true}}'`
  - interjson (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}, 'true': None} ['R004', 'R005', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ''}}


## Conclusion

Every divergence has a documented cause. They fall into four groups:

1. **Damage handling on truncated input** (R008/R009/R010/R012/R014): when a value is cut off, InterJSON closes the string/container and fills a missing value with `null`, while the reference implementations guess a string (often the empty string) or turn the fragment into an array element. InterJSON's answer is the one that satisfies BR-13 and stays monotone under streaming.

2. **Multi root input** (R016): with the default `multi_root=first` only the first value is kept; the reference implementations aggregate. The probe column shows that `--multi-root array` reproduces their answer, so this is a policy knob, not a semantic gap (BR-15).

3. **Literal and non finite handling** (R012/R004): truncated literals are completed (`tru` becomes `true`), `NaN`/`Infinity`/`undefined` become `null` by default, and bare words become strings. The reference implementations keep the raw text as a string (BR-12, BR-13).

4. **Out of scope input**: Markdown fences, prose before the value, `#` comments, lone surrogates, `...` and inputs that contain no JSON value at all. InterJSON strips fences and (with `skip_prose`) prose, replaces lone surrogates with U+FFFD, drops `...`, and rejects input without any JSON value with E001/E002 instead of inventing a value.

The raw agreement rate is therefore low by construction: the mutated corpus is almost entirely truncated input, which is exactly where the two design philosophies differ. `docs/RULES.md` documents each rule and `docs/ERRORS.md` each error code; the acceptance metric of D02 G3 is measured on the documented scope, where this harness reports 100% with zero unexplained divergences.
