"""Client tests. Run from `code/python`: `python -m unittest discover -s tests`."""

from __future__ import annotations

import json
import unittest

from jsonmend import Client, JsonMendError, find_binary


class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.binary = find_binary()

    def setUp(self) -> None:
        self.client = Client(binary=self.binary, timeout=10)

    def tearDown(self) -> None:
        self.client.close()

    def test_hello_reports_both_version_channels(self) -> None:
        hello = self.client.hello()
        self.assertEqual(hello["name"], "jsonmend")
        self.assertEqual(hello["engine"], "1.1.0")
        self.assertEqual(hello["registry"], "0.8.0")
        self.assertEqual(hello["protocol"], 1)
        self.assertIn("analyze", hello["capabilities"])

    def test_repair(self) -> None:
        result = self.client.repair("{'a':1,}")
        self.assertEqual(result["text"], '{"a":1}')
        self.assertEqual(result["exactness"], "cosmetic")
        self.assertIn("R005", [r["code"] for r in result["repairs"]])

    def test_analyze_blocks_an_ambiguous_repair(self) -> None:
        plan = self.client.analyze('{"words":["a" "b"]}', profile="execution")
        self.assertEqual(plan["decision"], "ambiguous")
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["error"]["code"], "E011")
        self.assertIn("Re-emit", plan["retry"]["prompt"])

    def test_analyze_accepts_a_json_schema_subset(self) -> None:
        plan = self.client.analyze(
            '{"query":"x","limit":0}',
            profile="agent",
            schema_json={
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1},
                },
                "required": ["query", "limit"],
            },
        )
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["schema_total"], 2)
        self.assertEqual(plan["schema_satisfied"], 1)

    def test_unsupported_schema_keyword_is_an_error(self) -> None:
        with self.assertRaises(JsonMendError) as caught:
            self.client.analyze("{}", schema_json={"$ref": "#/x"})
        self.assertEqual(caught.exception.code, "E070")
        self.assertIn("$ref", caught.exception.message)

    def test_validate(self) -> None:
        self.assertTrue(self.client.validate('{"a":1}')["valid"])
        bad = self.client.validate("{a:1,}")
        self.assertFalse(bad["valid"])
        self.assertEqual(bad["error"]["code"], "E010")
        self.assertEqual(bad["repaired"], '{"a":1}')

    def test_readiness(self) -> None:
        ready = self.client.readiness(
            '{"query":"x","limit":10}', schema="{!query:string,!limit:integer}"
        )
        self.assertEqual(ready["syntax_permille"], 1000)
        self.assertEqual(ready["schema_permille"], 1000)
        self.assertTrue(ready["verdict"]["ok"])

    def test_watch(self) -> None:
        self.client.watch_start(schema="{!a:string}")
        first = self.client.watch_feed('{"a":"x"}')
        kinds = [event["kind"] for event in first["events"]]
        self.assertIn("field_ready", kinds)
        self.assertIn("root_ready", kinds)
        final = self.client.watch_finish()
        self.assertEqual(final["final"]["value"], {"a": "x"})

    def test_llm_stream(self) -> None:
        self.client.llm_open("anthropic")
        events = [
            '{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}',
            '{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\":\\"Paris\\"}"}}',
            '{"type":"content_block_stop","index":0}',
        ]
        for event in events:
            self.client.llm_feed(event)
        closed = self.client.llm_close()
        self.assertEqual(closed["calls"][0]["name"], "get_weather")
        self.assertEqual(closed["calls"][0]["value"], {"location": "Paris"})
        self.assertEqual(closed["calls"][0]["end"], "complete")

    def test_unknown_profile_is_rejected(self) -> None:
        with self.assertRaises(JsonMendError) as caught:
            self.client.analyze("{}", profile="nope")
        self.assertEqual(caught.exception.code, "E050")


if __name__ == "__main__":
    unittest.main()
