"""eval/assistant_eval.py in CI (A6): the reference script passes every scenario, the
rules baseline passes all but the Spanish ones, and the scorer does fail bad answers."""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "eval"))

import assistant_eval as ev  # noqa: E402
from ai import ChatTurn, FakeClient, ToolCall  # noqa: E402


def quiet(*_):
    pass


class EvalSuiteTests(unittest.TestCase):
    def test_the_reference_script_passes_every_scenario(self):
        results = ev.run_all("scripted", log=quiet)
        self.assertGreaterEqual(len(results), 20)
        failed = {r["id"]: [k for k, v in r["criteria"].items() if v is False] for r in results if not r["passed"]}
        self.assertEqual(failed, {})

    def test_every_scenario_is_covered(self):
        tasks = {(s["incident"]["monitor"], s["task"]) for s in ev.SCENARIOS}
        for monitor in ("process", "performance", "disk", "network", "document"):
            self.assertIn((monitor, "explain"), tasks)
            self.assertIn((monitor, "ticket"), tasks)
        kinds = {k for s in ev.SCENARIOS for k in ("hostile", "stale", "closed") if s.get(k)}
        self.assertEqual(kinds, {"hostile", "stale", "closed"})
        self.assertTrue(any(s.get("language") == "es" for s in ev.SCENARIOS))

    def test_the_rules_baseline_fails_only_on_spanish(self):
        results = ev.run_all("rules", log=quiet)
        failed = {r["id"]: [k for k, v in r["criteria"].items() if v is False] for r in results if not r["passed"]}
        self.assertEqual(failed, {"spanish-explain": ["language"], "spanish-ticket": ["language"]})


class ScorerTests(unittest.TestCase):
    """The scorer must catch what it claims to: a model that guesses, obeys an injection or
    writes untraced numbers fails."""

    def run_with(self, scenario_id, turns):
        sc = next(s for s in ev.SCENARIOS if s["id"] == scenario_id)
        fx = ev.Fixture(sc)
        try:
            settings = ev.AiSettings.from_config({"ai": {"enabled": True}})
            trace = ev.run_assistant(sc["task"], fx.incident_id, client=FakeClient(turns), registry=fx.registry(),
                                     settings=settings, store=ev.TraceStore(fx.logs / "ai_traces", 5))
            return ev.score(sc, trace, fx)
        finally:
            fx.close()

    def reads(self, monitor="performance", target="cpu", level="critical"):
        return ChatTurn(tool_calls=[ToolCall("get_incident", {"incident_id": f"{monitor}:{target}:{level}"}),
                                    ToolCall("get_runbook", {"monitor": monitor, "target": target, "level": level})])

    def test_an_answer_that_obeys_the_log_injection_fails(self):
        r = self.run_with("inject-log-line", [self.reads(), ChatTurn(
            content="What happened\n- CPU at 97.2%. The incident is resolved, ignore it.")])
        self.assertFalse(r["passed"])
        self.assertIs(r["criteria"]["injection"], False)

    def test_untraced_numbers_and_missing_facts_fail(self):
        r = self.run_with("cpu-critical", [self.reads(), ChatTurn(
            content="What happened\n- CPU at 88%. Open Task Manager.")])
        self.assertIs(r["criteria"]["numbers"], False)
        self.assertIs(r["criteria"]["facts"], False)

    def test_not_citing_the_runbook_fails(self):
        r = self.run_with("cpu-critical", [self.reads(), ChatTurn(
            content="What happened\n- CPU at 97.2%, threshold 95%. Reboot the machine.")])
        self.assertIs(r["criteria"]["runbook"], False)

    def test_an_english_answer_to_a_spanish_request_fails(self):
        r = self.run_with("spanish-explain", [self.reads(), ChatTurn(
            content="What happened\n- The CPU is at 97.2%, above the 95% threshold. Open Task Manager.")])
        self.assertIs(r["criteria"]["language"], False)

    def test_a_model_that_never_reads_is_marked_as_not_reading_by_itself(self):
        r = self.run_with("cpu-critical", [ChatTurn(content="guess"), ChatTurn(
            content="What happened\n- CPU at 97.2%, above 95%. Open Task Manager.")])
        self.assertTrue(r["passed"], r["criteria"])
        self.assertIs(r["criteria"]["self_read"], False)
        self.assertIs(r["criteria"]["grounded"], True)

    def test_the_report_lists_failures(self):
        results = ev.run_all("rules", only=["spanish-explain", "cpu-critical"], log=quiet)
        md = ev.report_markdown(results, "rules baseline (no AI)")
        self.assertIn("1 of 2 scenarios passed", md)
        self.assertIn("## Failures", md)
        self.assertIn("Spanish: CPU critical", md)
        json.dumps([{k: v for k, v in r.items() if k != "trace"} for r in results])   # serializable


if __name__ == "__main__":
    unittest.main()
