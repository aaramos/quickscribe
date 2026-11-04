"""Run from sidecar/: .venv/bin/python -m unittest discover -s tests -t ."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from prompts import FACTORY_PROMPTS, MAX_PROMPT_TOKENS, PromptError, PromptStore


class PromptStoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "nested" / "prompts.json"
        self.store = PromptStore(self.path)

    def test_every_mode_starts_on_factory_text(self):
        self.assertEqual([e["id"] for e in self.store.entries()], ["polish", "concise", "active_voice"])
        for entry in self.store.entries():
            self.assertEqual(entry["prompt"], entry["factory"])
            self.assertFalse(entry["custom"])

    def test_saved_prompt_applies_at_once_and_survives_restart(self):
        self.store.save("concise", "Be brief.")
        self.assertEqual(self.store.prompt("concise"), "Be brief.")
        self.assertEqual(PromptStore(self.path).prompt("concise"), "Be brief.")
        self.assertEqual(self.store.prompt("polish"), FACTORY_PROMPTS["polish"])

    def test_reset_restores_factory_text_exactly(self):
        self.store.save("polish", "Custom.")
        entry = self.store.reset("polish")
        self.assertEqual(entry["prompt"], FACTORY_PROMPTS["polish"])
        self.assertFalse(entry["custom"])
        self.assertEqual(PromptStore(self.path).prompt("polish"), FACTORY_PROMPTS["polish"])

    def test_factory_text_is_never_written_to_the_override_file(self):
        self.store.save("polish", FACTORY_PROMPTS["polish"])
        self.assertEqual(json.loads(self.path.read_text()), {})

    def test_empty_and_oversized_prompts_are_refused_and_change_nothing(self):
        self.store.save("polish", "Keep me.")
        for bad in ("   \n", "x" * (MAX_PROMPT_TOKENS * 4 + 1)):
            with self.assertRaises(PromptError):
                self.store.save("polish", bad)
        self.assertEqual(self.store.prompt("polish"), "Keep me.")

    def test_prompt_exactly_at_the_limit_is_accepted(self):
        self.store.save("polish", "x" * (MAX_PROMPT_TOKENS * 4))

    def test_damaged_file_falls_back_to_factory(self):
        self.path.parent.mkdir(parents=True)
        for junk in ("{not json", "[1, 2]", '{"polish": 7, "nope": "x", "concise": "  "}'):
            self.path.write_text(junk)
            store = PromptStore(self.path)
            for mode, text in FACTORY_PROMPTS.items():
                self.assertEqual(store.prompt(mode), text)

    def test_factory_prompts_keep_the_prd_wording(self):
        self.assertTrue(FACTORY_PROMPTS["polish"].startswith("You are a text refinement engine"))
        for text in FACTORY_PROMPTS.values():
            self.assertIn('"um," "uh," "er," "ah," "you know," "like," "basically,"', text)
            self.assertIn("No commentary, no explanation, no markdown fences.", text)
        self.assertIn('"Sarah wrote the report."', FACTORY_PROMPTS["active_voice"])
        self.assertIn('"I just wanted to say"', FACTORY_PROMPTS["concise"])


class PromptRoutesTests(unittest.TestCase):
    """The routes with a stand-in model: what reaches the model, and the raw fallback."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cfg = Path(cls.dir.name) / "config.toml"
        real = (Path(__file__).resolve().parent.parent / "config.toml").read_text()
        cfg.write_text(real
                       .replace('~/Library/QuickScribe/prompts.json', f'{cls.dir.name}/prompts.json')
                       .replace('~/Library/QuickScribe/history.sqlite3', f'{cls.dir.name}/history.sqlite3'))
        with mock.patch.dict(os.environ, {"QUICKSCRIBE_CONFIG": str(cfg)}):
            import server
        cls.server = server
        from fastapi.testclient import TestClient
        cls.client = TestClient(server.app)  # no lifespan: nothing warms a real model

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def setUp(self):
        self.seen = []
        async def fake_polish(text, system_prompt):
            self.seen.append(system_prompt)
            return f"clean:{text}", False
        patcher = mock.patch.object(self.server.polisher, "polish", fake_polish)
        patcher.start()
        self.addCleanup(patcher.stop)
        for mode in FACTORY_PROMPTS:
            self.client.delete(f"/prompts/{mode}")

    def test_each_mode_sends_its_own_prompt(self):
        for mode, text in FACTORY_PROMPTS.items():
            self.assertEqual(self.client.post("/polish", json={"text": "hi", "profile": mode}).json()["text"], "clean:hi")
            self.assertEqual(self.seen[-1], text)

    def test_rewrite_still_works_and_unknown_profile_is_refused(self):
        self.assertEqual(self.client.post("/polish", json={"text": "hi", "profile": "rewrite"}).status_code, 200)
        self.assertIn("Rewrite this dictated text", self.seen[-1])
        self.assertEqual(self.client.post("/polish", json={"text": "hi", "profile": "nope"}).status_code, 400)

    def test_edit_changes_the_very_next_polish_and_reset_undoes_it(self):
        self.assertEqual(self.client.put("/prompts/concise", json={"prompt": "Mine."}).json()["custom"], True)
        self.client.post("/polish", json={"text": "hi", "profile": "concise"})
        self.assertEqual(self.seen[-1], "Mine.")
        self.assertEqual(self.client.delete("/prompts/concise").json()["prompt"], FACTORY_PROMPTS["concise"])
        self.client.post("/polish", json={"text": "hi", "profile": "concise"})
        self.assertEqual(self.seen[-1], FACTORY_PROMPTS["concise"])

    def test_test_route_uses_the_draft_without_saving_it(self):
        r = self.client.post("/prompts/test", json={"text": "hi", "prompt": "Draft."})
        self.assertEqual(r.json()["text"], "clean:hi")
        self.assertEqual(self.seen[-1], "Draft.")
        modes = {m["id"]: m for m in self.client.get("/prompts").json()["modes"]}
        self.assertFalse(modes["polish"]["custom"])

    def test_bad_requests(self):
        self.assertEqual(self.client.put("/prompts/nope", json={"prompt": "x"}).status_code, 404)
        self.assertEqual(self.client.delete("/prompts/nope").status_code, 404)
        self.assertEqual(self.client.put("/prompts/polish", json={"prompt": "  "}).status_code, 422)
        self.assertEqual(self.client.post("/prompts/test", json={"text": "hi", "prompt": ""}).status_code, 422)


class PolishFallbackTests(unittest.IsolatedAsyncioTestCase):
    async def test_failed_cleanup_returns_the_raw_text(self):
        from polish import Polisher
        polisher = Polisher(base_url="http://127.0.0.1:9/v1", model="none", timeout_s=1)
        with mock.patch("polish._api_key", return_value="test"):
            text, degraded = await polisher.polish("  my raw words ", FACTORY_PROMPTS["polish"])
        await polisher.close()
        self.assertEqual(text, "my raw words")
        self.assertTrue(degraded)


if __name__ == "__main__":
    unittest.main()
