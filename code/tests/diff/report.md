# JSONMend differential report

Reference: `json-repair` (Python) as primary oracle, `jsonrepair` (TypeScript/Node) as secondary oracle.

## Summary

| metric | value |
| --- | --- |
| cases | 389 |
| hand written | 86 (agreement 61.6%) |
| mutated | 303 (agreement 47.2%) |
| semantic agreement | 196 (50.4%) |
| both reject the input | 0 |
| divergences | 193 |
| divergences with a documented cause | 193 |
| unexplained divergences | 0 |
| documented-scope agreement | 100.0% |
| agreement with jsonrepair (node) | 59.4% (227/382) |

## Divergence classes

Every class is the set of repair rules JSONMend applied to reach
its answer; the referenced rule is why the two libraries differ.

| rules applied | count | documented cause |
| --- | --- | --- |
| `R010+R008+R009` | 15 | string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R008+R009` | 8 | missing value filled with null (BR-13); container closed (BR-13) |
| `jsonmend rejects, jsonrepair repairs (E001/E002/E040)` | 8 | FR-01 no JSON value found (E001/E002/E040); jsonrepair invents a value |
| `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 8 | missing comma inserted (BR-06); bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R012` | 6 | literal converted or completed (BR-12, BR-13) |
| `R010+R008+R009+R009` | 6 | string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007` | 5 | missing colon inserted (BR-05) |
| `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 5 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); duplicate key merged (BR-19); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 5 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 5 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R008+R009+R009` | 4 | missing value filled with null (BR-13); container closed (BR-13) |
| `R016` | 4 | unexpected content dropped (BR-15, multi_root=first default) |
| `R007+R004+R006+R010+R008+R009+R009` | 4 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R008+R005+R016` | 4 | missing value filled with null (BR-13); extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `prose (skip_prose off by default)` | 3 | FR-08 skip_prose off by default (probe: --skip-prose agrees) |
| `R012+R009` | 3 | literal converted or completed (BR-12, BR-13); container closed (BR-13) |
| `R014+R010+R009` | 3 | half escape dropped (BR-08); string closed (BR-13); container closed (BR-13) |
| `R014` | 3 | half escape dropped (BR-08) |
| `R010+R009+R009` | 3 | string closed (BR-13); container closed (BR-13) |
| `R012+R009+R009` | 3 | literal converted or completed (BR-12, BR-13); container closed (BR-13) |
| `R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 3 | missing comma inserted (BR-06); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R012+R004+R008+R005` | 3 | literal converted or completed (BR-12, BR-13); bare word quoted (BR-10); missing value filled with null (BR-13); extra comma removed (BR-06) |
| `R012+R006+R010+R008+R009+R009` | 3 | literal converted or completed (BR-12, BR-13); missing comma inserted (BR-06); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R012+R006+R004+R008+R017` | 3 | literal converted or completed (BR-12, BR-13); missing comma inserted (BR-06); bare word quoted (BR-10); missing value filled with null (BR-13); extra closer dropped (BR-14) |
| `multi-root (BR-15 policy)` | 2 | BR-15 multi_root=first (probe: --multi-root array agrees) |
| `R005` | 2 | extra comma removed (BR-06) |
| `R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 2 | missing colon inserted (BR-05); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); container closed (BR-13) |
| `R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 2 | missing comma inserted (BR-06); missing colon inserted (BR-05); bare word quoted (BR-10); duplicate key merged (BR-19); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 2 | missing colon inserted (BR-05); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); container closed (BR-13) |
| `R006+R004+R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 2 | missing comma inserted (BR-06); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 2 | missing comma inserted (BR-06); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 2 | missing comma inserted (BR-06); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R007+R006+R004+R007+R006+R004+R007+R010+R009` | 2 | missing colon inserted (BR-05); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); container closed (BR-13) |
| `R007+R012+R006+R007+R004+R006+R010+R008+R009+R009` | 2 | missing colon inserted (BR-05); literal converted or completed (BR-12, BR-13); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007+R006+R004+R007+R010+R009+R009` | 2 | missing colon inserted (BR-05); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); container closed (BR-13) |
| `R006+R007+R004+R006+R010+R008+R009+R009` | 2 | missing comma inserted (BR-06); missing colon inserted (BR-05); bare word quoted (BR-10); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R007+R010+R009+R009` | 2 | missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R008+R016` | 2 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R005+R016` | 2 | extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `R005+R005` | 1 | extra comma removed (BR-06) |
| `R008+R006+R004+R008` | 1 | missing value filled with null (BR-13); missing comma inserted (BR-06); bare word quoted (BR-10) |
| `R004` | 1 | bare word quoted (BR-10) |
| `R020` | 1 | ellipsis dropped (BR-16) |
| `R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); missing comma inserted (BR-06); string closed (BR-13); container closed (BR-13) |
| `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 1 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); duplicate key merged (BR-19); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 1 | bare word quoted (BR-10); missing comma inserted (BR-06); missing colon inserted (BR-05); duplicate key merged (BR-19); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); missing comma inserted (BR-06); string closed (BR-13); container closed (BR-13) |
| `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 1 | missing colon inserted (BR-05); bare word quoted (BR-10); missing comma inserted (BR-06); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R008+R015+R005+R016` | 1 | missing value filled with null (BR-13); invalid escape repaired (BR-08); extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `R004+R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 1 | bare word quoted (BR-10); missing comma inserted (BR-06); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 1 | bare word quoted (BR-10); missing comma inserted (BR-06); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); container closed (BR-13) |
| `R016+R006+R015+R009` | 1 | unexpected content dropped (BR-15, multi_root=first default); missing comma inserted (BR-06); invalid escape repaired (BR-08); container closed (BR-13) |
| `R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); missing comma inserted (BR-06); string closed (BR-13); container closed (BR-13) |
| `R007+R012+R006+R007+R004+R006+R010+R008+R009` | 1 | missing colon inserted (BR-05); literal converted or completed (BR-12, BR-13); missing comma inserted (BR-06); bare word quoted (BR-10); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R016+R006+R004+R008+R017` | 1 | unexpected content dropped (BR-15, multi_root=first default); missing comma inserted (BR-06); bare word quoted (BR-10); missing value filled with null (BR-13); extra closer dropped (BR-14) |
| `R004+R007+R006+R004+R007+R010+R009+R009` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); missing comma inserted (BR-06); string closed (BR-13); container closed (BR-13) |
| `R004+R007+R010+R009+R009` | 1 | bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R008+R016+R008` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R008+R008` | 1 | missing value filled with null (BR-13) |
| `R008+R016+R016+R008+R008+R015+R005+R016` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); invalid escape repaired (BR-08); extra comma removed (BR-06) |
| `R008+R016+R008+R008+R015+R005+R016` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); invalid escape repaired (BR-08); extra comma removed (BR-06) |
| `R008+R016+R016+R017` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); extra closer dropped (BR-14) |
| `R008+R016+R017` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); extra closer dropped (BR-14) |
| `R008+R016+R004+R008` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); bare word quoted (BR-10) |
| `R008+R004+R008` | 1 | missing value filled with null (BR-13); bare word quoted (BR-10) |
| `R004+R008` | 1 | bare word quoted (BR-10); missing value filled with null (BR-13) |
| `R008+R016+R004+R008+R005` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); bare word quoted (BR-10); extra comma removed (BR-06) |
| `R008+R004+R008+R005` | 1 | missing value filled with null (BR-13); bare word quoted (BR-10); extra comma removed (BR-06) |
| `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009` | 1 | missing comma inserted (BR-06); missing colon inserted (BR-05); bare word quoted (BR-10); literal converted or completed (BR-12, BR-13); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R006+R004+R007+R006+R004+R007+R010+R009` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R006+R004+R007+R010+R009+R009` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); missing colon inserted (BR-05); string closed (BR-13); container closed (BR-13) |
| `R006+R010+R008+R009+R009` | 1 | missing comma inserted (BR-06); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R006+R010+R008+R009` | 1 | missing comma inserted (BR-06); string closed (BR-13); missing value filled with null (BR-13); container closed (BR-13) |
| `R015+R006+R008+R008+R015+R005+R016` | 1 | invalid escape repaired (BR-08); missing comma inserted (BR-06); missing value filled with null (BR-13); extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `R015+R008+R015+R005+R016` | 1 | invalid escape repaired (BR-08); missing value filled with null (BR-13); extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default) |
| `R015+R005+R006+R008+R015+R016` | 1 | invalid escape repaired (BR-08); extra comma removed (BR-06); missing comma inserted (BR-06); missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default) |
| `R015+R015+R016` | 1 | invalid escape repaired (BR-08); unexpected content dropped (BR-15, multi_root=first default) |
| `R008+R016+R006+R004+R008+R017` | 1 | missing value filled with null (BR-13); unexpected content dropped (BR-15, multi_root=first default); missing comma inserted (BR-06); bare word quoted (BR-10); extra closer dropped (BR-14) |
| `R008+R006+R004+R008+R017` | 1 | missing value filled with null (BR-13); missing comma inserted (BR-06); bare word quoted (BR-10); extra closer dropped (BR-14) |
| `R006+R004+R008+R017` | 1 | missing comma inserted (BR-06); bare word quoted (BR-10); missing value filled with null (BR-13); extra closer dropped (BR-14) |
| `R008+R005+R016+R006+R004+R008+R017` | 1 | missing value filled with null (BR-13); extra comma removed (BR-06); unexpected content dropped (BR-15, multi_root=first default); missing comma inserted (BR-06); bare word quoted (BR-10); extra closer dropped (BR-14) |
| `R008+R005+R006+R004+R008+R017` | 1 | missing value filled with null (BR-13); extra comma removed (BR-06); missing comma inserted (BR-06); bare word quoted (BR-10); extra closer dropped (BR-14) |

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
| R016 | 30 |
| R005 | 22 |
| R017 | 11 |
| R018 | 9 |
| R015 | 8 |
| R014 | 6 |
| R020 | 1 |

## Unexplained divergences

None: every divergence is attributed to a documented rule or policy.


## Samples per class

### `R010+R008+R009`

- input `'{"'`
  - jsonmend (rc 0): {'': None} ['R008', 'R009', 'R010']
  - json-repair: {}
- input `'{"n'`
  - jsonmend (rc 0): {'n': None} ['R008', 'R009', 'R010']
  - json-repair: ['n']
- input `'{"na'`
  - jsonmend (rc 0): {'na': None} ['R008', 'R009', 'R010']
  - json-repair: ['na']
- input `'{"nam'`
  - jsonmend (rc 0): {'nam': None} ['R008', 'R009', 'R010']
  - json-repair: ['nam']
- input `'{"name'`
  - jsonmend (rc 0): {'name': None} ['R008', 'R009', 'R010']
  - json-repair: ['name']

### `R008+R009`

- input `'{"a":'`
  - jsonmend (rc 0): {'a': None} ['R008', 'R009']
  - json-repair: {'a': ''}
- input `'{"a":-'`
  - jsonmend (rc 0): {'a': None} ['R008', 'R009']
  - json-repair: {'a': ''}
- input `'{"name"'`
  - jsonmend (rc 0): {'name': None} ['R008', 'R009']
  - json-repair: ['name']
- input `'{"name":'`
  - jsonmend (rc 0): {'name': None} ['R008', 'R009']
  - json-repair: {'name': ''}
- input `'{"name":"moonbit","tags"'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': None} ['R008', 'R009']
  - json-repair: {'name': 'moonbit'}

### `jsonmend rejects, jsonrepair repairs (E001/E002/E040)`

- input `''`
  - jsonmend (rc 3): None []
  - json-repair: ''
- input `'   '`
  - jsonmend (rc 3): None []
  - json-repair: ''
- input `'\n\n'`
  - jsonmend (rc 3): None []
  - json-repair: ''
- input `'hello world'`
  - jsonmend (rc 3): None []
  - json-repair: ''
- input `'}'`
  - jsonmend (rc 3): None []
  - json-repair: ''

### `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":""moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': '', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":""moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': '', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"m"oonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'm', 'oonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'm"oonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"mo"onbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'mo', 'onbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'mo"onbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moo"nbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moo', 'nbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moo"nbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R012`

- input `'{"a":undefined}'`
  - jsonmend (rc 0): {'a': None} ['R012']
  - json-repair: {'a': 'undefined'}
- input `'{"a":NaN}'`
  - jsonmend (rc 0): {'a': None} ['R012']
  - json-repair: {'a': nan}
- input `'{"a":Infinity}'`
  - jsonmend (rc 0): {'a': None} ['R012']
  - json-repair: {'a': inf}
- input `'{"a":-Infinity}'`
  - jsonmend (rc 0): {'a': None} ['R012']
  - json-repair: {'a': -inf}
- input `'nul'`
  - jsonmend (rc 0): None ['R012']
  - json-repair: ''

### `R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'': None}} ['R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}} ['R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ['n']}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, '': None}} ['R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"o'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'o': None}} ['R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}} ['R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}

### `R007`

- input `'{"a" 1}'`
  - jsonmend (rc 0): {'a': 1} ['R007']
  - json-repair: {'a': ''}
- input `'{"name":"moonbit","tags"["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags"["a","b"],"meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta"{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta"{"n': 12, 'ok': True}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n"12,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R007']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'rue'}}

### `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{""name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'': 'name', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{""name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'': 'name', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"n"ame":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'n': 'ame', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'n"ame': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"na"me":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'na': 'me', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'na"me': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"nam"e":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'nam': 'e', ':': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'nam"e': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit",""tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', '': 'tags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit",""tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', '': 'tags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","t"ags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 't': 'ags', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 't"ags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","ta"gs":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'ta': 'gs', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'ta"gs': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tag"s":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tag': 's', ':[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tag"s': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit","tags":["a","b"],""meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], '': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],""meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], '': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"m"eta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'm': 'eta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'm"eta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"me"ta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'me': 'ta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'me"ta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"met"a":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'met': 'a', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'met"a': {'n': 12, 'ok': True}}

### `R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}} ['R008', 'R009']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ['n']}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}} ['R008', 'R009']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ''}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}} ['R008', 'R009']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}} ['R008', 'R009']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ''}}

### `R016`

- input `'"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): 'name' ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{}"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {} ['R016']
  - json-repair: [['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit"},"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit'} ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"]},"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R004+R006+R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n:12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n:12,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n:12,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,""ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, '': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,""ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, '': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"o"k":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'o': 'k', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'o"k': True}}

### `R008+R005+R016`

- input `'{"name":"moonbit","tags"}:["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit'}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":}["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ''}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],"meta"}:{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b']}, {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],"meta":}{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None} ['R005', 'R008', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ''}, {'n': 12, 'ok': True}]

### `prose (skip_prose off by default)`

- input `'Here is the JSON:\n{"a":1}'`
  - jsonmend (rc 3): None []
  - json-repair: {'a': 1}
- input `'Sure! {"a":1}'`
  - jsonmend (rc 3): None []
  - json-repair: {'a': 1}
- input `'# python comment\n{"a":1}'`
  - jsonmend (rc 3): None []
  - json-repair: {'a': 1}

### `R012+R009`

- input `'{"a":tru'`
  - jsonmend (rc 0): {'a': True} ['R009', 'R012']
  - json-repair: {'a': 'tru'}
- input `'{"a":fals'`
  - jsonmend (rc 0): {'a': False} ['R009', 'R012']
  - json-repair: {'a': 'fals'}
- input `'{"a":nul'`
  - jsonmend (rc 0): {'a': None} ['R009', 'R012']
  - json-repair: {'a': 'nul'}

### `R014+R010+R009`

- input `'{"a":"\\'`
  - jsonmend (rc 0): {'a': ''} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\\'}
- input `'{"a":"\\u12'`
  - jsonmend (rc 0): {'a': ''} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\\u12'}
- input `'{"a":"\\uD83D'`
  - jsonmend (rc 0): {'a': '�'} ['R009', 'R010', 'R014']
  - json-repair: {'a': '\ud83d'}

### `R014`

- input `'{"a":"bad\\qescape"}'`
  - jsonmend (rc 0): {'a': 'badqescape'} ['R014']
  - json-repair: {'a': 'bad\\qescape'}
- input `'["\\uD800"]'`
  - jsonmend (rc 0): ['�'] ['R014']
  - json-repair: ['\ud800']
- input `'["\\uDC00x"]'`
  - jsonmend (rc 0): ['�x'] ['R014']
  - json-repair: ['\udc00x']

### `R010+R009+R009`

- input `'{"name":"moonbit","tags":["'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['']} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': []}
- input `'{"name":"moonbit","tags":["a","'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', '']} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a']}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":"true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true}}'}} ['R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true'}}

### `R012+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R009', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R009', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R009', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru'}}

### `R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a,"b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a,', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a,', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a",""b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', '', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a",""b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', '', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R012+R004+R008+R005`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t,rue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'rue': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't,rue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr,ue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'ue': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr,ue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru,e}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'e': None}} ['R004', 'R005', 'R008', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru,e'}}

### `R012+R006+R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t"rue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'rue}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr"ue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'ue}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru"e}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, 'e}}': None}} ['R006', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru'}}

### `R012+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":t}rue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'rue': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 't}rue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tr}ue}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'ue': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tr}ue'}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":tru}e}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, 'e': None} ['R004', 'R006', 'R008', 'R012', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'tru'}}

### `multi-root (BR-15 policy)`

- input `'{"a":1}{"b":2}'`
  - jsonmend (rc 0): {'a': 1} ['R016']
  - json-repair: [{'a': 1}, {'b': 2}]
- input `'{"a":1} {"b":2}'`
  - jsonmend (rc 0): {'a': 1} ['R016']
  - json-repair: [{'a': 1}, {'b': 2}]

### `R005`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R005']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,', 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R005']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,', 'ok': True}}

### `R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name"":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': ':', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name"":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': ':', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit"","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit"', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit"","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit"', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit","tags"":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags"":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R004+R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":[""a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['', 'a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":[""a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['', 'a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a"","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', ',', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a"","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', ',', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b""],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta":{"n', 12], 'ok': True}
- input `'{"name":"moonbit","tags":["a","b""],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta":{"n', 12], 'ok': True}

### `R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta"":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta"":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R012+R006+R007+R004+R006+R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{""n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'': None, ':12,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{""n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'': None, ':12,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R006+R004+R007+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ':12,', 'ok': ':true}}'}} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ':12,', 'ok': ':true}}'}} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R007+R004+R006+R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1"2,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2,': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2,"ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12","ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, ',': 'ok', ':true}}': None}} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}
- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R016`

- input `'{"name"}:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': None} ['R008', 'R016']
  - json-repair: [['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":}"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': None} ['R008', 'R016']
  - json-repair: [{'name': ''}, ['a', 'b'], {'n': 12, 'ok': True}]

### `R005+R016`

- input `'{"name":"moonbit",}"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit'} ['R005', 'R016']
  - json-repair: [{'name': 'moonbit'}, ['a', 'b'], {'n': 12, 'ok': True}]
- input `'{"name":"moonbit","tags":["a","b"],}"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R005', 'R016']
  - json-repair: [{'name': 'moonbit', 'tags': ['a', 'b']}, {'n': 12, 'ok': True}]

### `R005+R005`

- input `'{"a":1,,}'`
  - jsonmend (rc 0): {'a': 1} ['R005']
  - json-repair: {'a': '1,'}

### `R008+R006+R004+R008`

- input `'{"a":- 1}'`
  - jsonmend (rc 0): {'a': None, '1': None} ['R004', 'R006', 'R008']
  - json-repair: {'a': ''}

### `R004`

- input `'{"a":1_000}'`
  - jsonmend (rc 0): {'a': '1_000'} ['R004']
  - json-repair: {'a': 1000}

### `R020`

- input `'{"a":...,"b":2}'`
  - jsonmend (rc 0): {'b': 2} ['R020']
  - json-repair: {'a': '...', 'b': 2}

### `R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': ':', 'moonbit': ',', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name:': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R006+R007+R004+R006+R007+R004+R006+R007+R004+R018+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', ',': 'b', ':[': 'a', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012', 'R018']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit,"tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit,', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit",tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ':[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R004+R006+R007+R004+R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit","tags:["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags:[': 'a', ',': 'b', '],': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R015+R005+R016`

- input `'{"name":"moonbit","tags":"a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': 'a', 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': 'a', 'b"],"meta': {'n': 12, 'ok': True}}

### `R004+R006+R006+R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":[a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', ',', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R006+R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a",b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', '],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R004+R006+R006+R012+R006+R006+R004+R006+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b],', 'meta', ':{', None, ':12,', 'ok', ':true}}']} ['R004', 'R006', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b],', 'meta":{"n', 12], 'ok': True}

### `R016+R006+R015+R009`

- input `'{"name":"moonbit","tags":["a","b","meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b', 'meta', {'n': 12, 'ok': True}]} ['R006', 'R009', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit","tags":["a","b"],meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta:{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta:{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta:{"n': 12, 'ok': True}

### `R016+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': 'n', '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': 'n', '12,"ok': True}

### `R004+R007+R006+R004+R007+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ':12,', 'ok': ':true}}'}} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R004+R007+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ':true}}'}} ['R004', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,ok'}}

### `R008+R016+R008`

- input `'{"name",:"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': None, 'moonbit': None, 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R008`

- input `'{"name":,"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': None, 'moonbit': None, 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}} ['R008']
  - json-repair: {'name': '', 'moonbit","tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R016+R016+R008+R008+R015+R005+R016`

- input `'{"name":"moonbit","tags",:["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': None, 'a': None, 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R016+R008+R008+R015+R005+R016`

- input `'{"name":"moonbit","tags":,["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': None, 'a': None, 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': '', 'a","b"],"meta': {'n': 12, 'ok': True}}

### `R008+R016+R016+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta",:{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None, 'n': 12, 'ok': True} ['R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R016+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":,{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': None, 'n': 12, 'ok': True} ['R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': '', 'n': 12, 'ok': True}

### `R008+R016+R004+R008`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n",:12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None, '12': None, 'ok': True}} ['R004', 'R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R004+R008`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":,12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None, '12': None, 'ok': True}} ['R004', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '', '12,"ok': True}}

### `R004+R008`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1,2,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1, '2': None, 'ok': True}} ['R004', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '1,2', 'ok': True}}

### `R008+R016+R004+R008+R005`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok",:true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None, 'true': None}} ['R004', 'R005', 'R008', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R004+R008+R005`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":,true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None, 'true': None}} ['R004', 'R005', 'R008']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ''}}

### `R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit","tags":"["a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': '[', 'a': ',', 'b': '],', 'meta': ':{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': '["a",', 'b"],"meta': {'n': 12, 'ok': True}}

### `R006+R007+R004+R006+R007+R012+R006+R007+R004+R006+R010+R008+R009`

- input `'{"name":"moonbit","tags":["a","b"]","meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], ',': 'meta', ':{': None, ':12,': 'ok', ':true}}': None} ['R004', 'R006', 'R007', 'R008', 'R009', 'R010', 'R012']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R006+R004+R007+R006+R004+R007+R010+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":"{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': '{', 'n': ':12,', 'ok': ':true}}'} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': '{"n":12', 'ok': True}

### `R006+R004+R007+R010+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":"12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12,', 'ok': ':true}}'}} ['R004', 'R006', 'R007', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': '12', 'ok': True}}

### `R006+R010+R008+R009+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true"}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True, '}}': None}} ['R006', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': 'true'}}

### `R006+R010+R008+R009`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":true}"}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}, '}': None} ['R006', 'R008', 'R009', 'R010']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R015+R006+R008+R008+R015+R005+R016`

- input `'{"name":"moonbit","tags":[}"a","b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': [], 'a': None, 'b': None} ['R005', 'R006', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': [], 'a","b"],"meta': {'n': 12, 'ok': True}}

### `R015+R008+R015+R005+R016`

- input `'{"name":"moonbit","tags":["a"},"b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a'], 'b': None} ['R005', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a'], 'b"],"meta': {'n': 12, 'ok': True}}

### `R015+R005+R006+R008+R015+R016`

- input `'{"name":"moonbit","tags":["a",}"b"],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a'], 'b': None} ['R005', 'R006', 'R008', 'R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a'], 'b"],"meta': {'n': 12, 'ok': True}}

### `R015+R015+R016`

- input `'{"name":"moonbit","tags":["a","b"}],"meta":{"n":12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b']} ['R015', 'R016']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': True}}

### `R008+R016+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n"}:12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}, '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {}, '12,"ok': True}

### `R008+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":}12,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': None}, '12': None, 'ok': True} ['R004', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': ''}, '12,"ok': True}

### `R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":1}2,"ok":true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1}, '2': None, 'ok': True} ['R004', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 1}, '2,"ok': True}

### `R008+R005+R016+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok"}:true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}, 'true': None} ['R004', 'R005', 'R006', 'R008', 'R016', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12}}

### `R008+R005+R006+R004+R008+R017`

- input `'{"name":"moonbit","tags":["a","b"],"meta":{"n":12,"ok":}true}}'`
  - jsonmend (rc 0): {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': None}, 'true': None} ['R004', 'R005', 'R006', 'R008', 'R017']
  - json-repair: {'name': 'moonbit', 'tags': ['a', 'b'], 'meta': {'n': 12, 'ok': ''}}
