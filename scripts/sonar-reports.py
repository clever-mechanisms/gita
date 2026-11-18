#!/usr/bin/env python3
"""Convert SwiftLint, Periphery and jscpd JSON output into SonarQube's generic external issue format.

usage: sonar-reports.py SWIFTLINT_JSON PERIPHERY_JSON JSCPD_JSON OUTPUT_JSON

Paths in the output are relative to the repository root, as the scanner expects.
"""
import json
import os
import sys

DUPLICATION_RULE = "jscpd.duplication"
ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def relative(path):
    absolute = os.path.realpath(path if os.path.isabs(path) else os.path.join(ROOT, path))
    return os.path.relpath(absolute, ROOT)


def rule(engine, rule_id, name, quality="MAINTAINABILITY", severity="MEDIUM", attribute="CLEAR"):
    return {
        "id": rule_id,
        "name": name,
        "description": f"{name} ({engine}; see CONTRIBUTING.md › Quality gate).",
        "engineId": engine,
        "cleanCodeAttribute": attribute,
        "impacts": [{"softwareQuality": quality, "severity": severity}],
    }


def issue(rule_id, message, path, line):
    return {
        "ruleId": rule_id,
        "primaryLocation": {
            "message": message,
            "filePath": relative(path),
            "textRange": {"startLine": max(int(line or 1), 1)},
        },
    }


def load(path, default):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return default
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def swiftlint(path):
    rules, issues = {}, []
    for violation in load(path, []):
        rule_id = "swiftlint." + violation["rule_id"]
        rules.setdefault(rule_id, rule("swiftlint", rule_id, "SwiftLint: " + violation.get("type", violation["rule_id"])))
        issues.append(issue(rule_id, violation["reason"], violation["file"], violation.get("line")))
    return rules, issues


def periphery(path):
    rules, issues = {}, []
    for result in load(path, []):
        hints = result.get("hints") or ["unused"]
        rule_id = "periphery." + hints[0]
        rules.setdefault(rule_id, rule("periphery", rule_id, "Dead code: " + hints[0], attribute="FOCUSED"))
        location = result.get("location", "")
        file, line = (location.split(":") + ["1"])[:2]
        kind = result.get("kind", "declaration")
        issues.append(issue(rule_id, f"Unused {kind} '{result.get('name', '')}' ({hints[0]}).", file, line))
    return rules, issues


def jscpd(path):
    report = load(path, {"duplicates": []})
    rules = {DUPLICATION_RULE: rule("jscpd", DUPLICATION_RULE, "Duplicated code", attribute="DISTINCT")}
    issues = []
    for duplicate in report.get("duplicates", []):
        first, second = duplicate["firstFile"], duplicate["secondFile"]
        message = (f"{duplicate.get('lines', '?')} lines duplicated with {relative(second['name'])}:"
                   f"{second['start']}.")
        issues.append(issue(DUPLICATION_RULE, message, first["name"], first["start"]))
    return rules, issues


def main(arguments):
    if len(arguments) != 4:
        sys.exit(__doc__)
    rules, issues = {}, []
    for converter, path in zip((swiftlint, periphery, jscpd), arguments[:3]):
        found_rules, found_issues = converter(path)
        rules.update(found_rules)
        issues.extend(found_issues)
    with open(arguments[3], "w", encoding="utf-8") as handle:
        json.dump({"rules": list(rules.values()), "issues": issues}, handle, indent=2)
    print(f"sonar-reports: {len(issues)} external issues from SwiftLint, Periphery and jscpd")


if __name__ == "__main__":
    main(sys.argv[1:])
