#!/usr/bin/env python3
"""One-time SonarQube setup for Gita: quality gate, empty HTML profile, project assignment.

usage: scripts/sonar-setup.py

Reads SONAR_URL, SONAR_PROJECT_ID and SONAR_API_TOKEN from the untracked .sonar.txt (or SONAR_HOST_URL,
SONAR_PROJECT_KEY and SONAR_TOKEN from the environment). Safe to run again: it updates what already exists.
Needs a token allowed to administer quality gates and profiles.

The gate mirrors scripts/quality.sh: no issues of any kind (the Swift limits arrive as external issues), no
duplication, coverage of at least 80%, every hotspot reviewed and A ratings.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
GATE = "Gita macOS app"
PROFILE = "Gita Swift via HTML (no rules)"

# (metric, operator, error threshold)
CONDITIONS = [
    ("new_violations", "GT", "0"),
    ("violations", "GT", "0"),
    ("accepted_issues", "GT", "0"),
    ("new_duplicated_lines_density", "GT", "0"),
    ("duplicated_lines_density", "GT", "0"),
    ("new_coverage", "LT", "80"),
    ("coverage", "LT", "80"),
    ("new_security_hotspots_reviewed", "LT", "100"),
    ("security_hotspots_reviewed", "LT", "100"),
    ("new_software_quality_reliability_rating", "GT", "1"),
    ("new_software_quality_security_rating", "GT", "1"),
    ("new_software_quality_maintainability_rating", "GT", "1"),
    ("software_quality_reliability_rating", "GT", "1"),
    ("software_quality_security_rating", "GT", "1"),
    ("software_quality_maintainability_rating", "GT", "1"),
]


def settings():
    values = {}
    path = os.path.join(ROOT, ".sonar.txt")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    values[key] = value
    url = os.environ.get("SONAR_HOST_URL") or values.get("SONAR_URL")
    token = os.environ.get("SONAR_TOKEN") or values.get("SONAR_API_TOKEN")
    project = os.environ.get("SONAR_PROJECT_KEY") or values.get("SONAR_PROJECT_ID")
    if not (url and token and project):
        sys.exit("Set SONAR_URL, SONAR_PROJECT_ID and SONAR_API_TOKEN in .sonar.txt")
    return url.rstrip("/"), token, project


class Client:
    def __init__(self, url, token):
        self.url = url
        self.auth = "Basic " + base64.b64encode((token + ":").encode()).decode()

    def call(self, method, path, **params):
        query = urllib.parse.urlencode(params)
        url = f"{self.url}/api/{path}" + (f"?{query}" if method == "GET" and query else "")
        data = query.encode() if method == "POST" else None
        request = urllib.request.Request(url, data=data, method=method, headers={"Authorization": self.auth})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            raise SystemExit(f"{method} {path}: HTTP {error.code} {error.read().decode()[:300]}") from error


def ensure_gate(client, project):
    gates = client.call("GET", "qualitygates/list")["qualitygates"]
    if not any(gate["name"] == GATE for gate in gates):
        client.call("POST", "qualitygates/create", name=GATE)
    existing = client.call("GET", "qualitygates/show", name=GATE).get("conditions", [])
    by_metric = {condition["metric"]: condition for condition in existing}
    wanted = {metric for metric, _, _ in CONDITIONS}
    for condition in existing:
        if condition["metric"] not in wanted:
            client.call("POST", "qualitygates/delete_condition", id=condition["id"])
    for metric, operator, error in CONDITIONS:
        if metric in by_metric:
            client.call("POST", "qualitygates/update_condition", id=by_metric[metric]["id"], metric=metric,
                        op=operator, error=error)
        else:
            client.call("POST", "qualitygates/create_condition", gateName=GATE, metric=metric, op=operator,
                        error=error)
    client.call("POST", "qualitygates/select", gateName=GATE, projectKey=project)


def ensure_profile(client, project):
    profiles = client.call("GET", "qualityprofiles/search", language="web")["profiles"]
    if not any(profile["name"] == PROFILE for profile in profiles):
        client.call("POST", "qualityprofiles/create", language="web", name=PROFILE)
    client.call("POST", "qualityprofiles/add_project", language="web", qualityProfile=PROFILE, project=project)


def main():
    url, token, project = settings()
    client = Client(url, token)
    ensure_gate(client, project)
    ensure_profile(client, project)
    print(f"SonarQube: '{GATE}' gate and '{PROFILE}' profile assigned to {project}")


if __name__ == "__main__":
    main()
