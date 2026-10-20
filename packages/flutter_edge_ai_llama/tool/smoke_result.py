"""Require machine-reported execution of a real-model test, not a skipped suite."""
import json


def require_smoke_success(output, expected_name):
    tests = set()
    completed = set()
    successful = False
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "testStart" and expected_name in event.get("test", {}).get("name", ""):
            tests.add(event["test"]["id"])
        if event.get("type") == "testDone" and event.get("result") == "success" and not event.get("skipped", False) and not event.get("hidden", False):
            completed.add(event.get("testID"))
        if event.get("type") == "done" and event.get("success") is True:
            successful = True
    if not successful or not tests.intersection(completed):
        raise RuntimeError(f"Required smoke did not execute successfully: {expected_name}")
