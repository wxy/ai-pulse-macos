#!/usr/bin/env python3
"""Create a release draft from checked-in notes, without editing any release."""

import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, api_url, repository, token):
        self.url = f"{api_url.rstrip('/')}/repos/{repository}/releases"
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, method, suffix="", payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.url + suffix,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "User-Agent": "AI-Pulse-release-draft",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with self.opener.open(request, timeout=30) as response:
            return json.load(response)

    def find(self, tag):
        # The tag endpoint omits drafts. Authenticated list requests include
        # drafts, and older matching releases may be beyond the first page.
        page = 1
        while True:
            releases = self.request("GET", f"?per_page=100&page={page}")
            if not isinstance(releases, list):
                raise ReleaseError("Invalid release-list response; refusing to create.")
            for release in releases:
                if (
                    not isinstance(release, dict)
                    or type(release.get("id")) is not int
                    or not isinstance(release.get("tag_name"), str)
                    or type(release.get("draft")) is not bool
                ):
                    raise ReleaseError("Invalid release metadata; refusing to create.")
                if release["tag_name"] == tag:
                    return release
            if len(releases) < 100:
                return None
            page += 1


def main():
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    tag = os.environ.get("GITHUB_REF_NAME", "")
    sha = os.environ.get("GITHUB_SHA", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    parsed = urllib.parse.urlsplit(api_url)
    if not token:
        raise ReleaseError("GITHUB_TOKEN is required.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ReleaseError("A valid GITHUB_REPOSITORY is required.")
    if os.environ.get("GITHUB_REF_TYPE") != "tag" or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ReleaseError("A stable vX.Y.Z tag event is required.")
    if not re.fullmatch(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?", sha):
        raise ReleaseError("A commit GITHUB_SHA is required.")
    if (
        not parsed.hostname
        or parsed.username or parsed.password or parsed.query or parsed.fragment
        or not (parsed.scheme == "https" or (
            parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
        ))
    ):
        raise ReleaseError("GITHUB_API_URL must use HTTPS (or a loopback test server).")

    github = GitHub(api_url, repository, token)
    if github.find(tag) is not None:
        print(f"Release {tag} already exists; leaving all content and state unchanged.")
        return

    notes = Path("RELEASE_DRAFT.md").read_text(encoding="utf-8")
    first_line = next((line.strip() for line in notes.splitlines() if line.strip()), "")
    if not first_line.startswith("# "):
        raise ReleaseError("RELEASE_DRAFT.md must start with an H1 release title.")
    title = first_line[2:].strip()
    if not re.search(rf"(?<![\w.+-]){re.escape(tag[1:])}(?![\w.+-])", title):
        raise ReleaseError("The release-note title must match the event tag version.")
    payload = {
        "tag_name": tag,
        "target_commitish": sha,
        "name": title,
        "body": notes,
        "draft": True,
        "prerelease": False,
        "generate_release_notes": False,
    }
    try:
        created = github.request("POST", payload=payload)
    except urllib.error.HTTPError as error:
        # Another writer may have created the release after our lookup.
        # Recheck a conflict, but never PATCH a release or retry a POST.
        if error.code == 422 and github.find(tag) is not None:
            print(f"Release {tag} now exists; leaving all content and state unchanged.")
            return
        raise
    if (
        not isinstance(created, dict)
        or type(created.get("id")) is not int
        or created.get("tag_name") != tag
        or created.get("draft") is not True
    ):
        raise ReleaseError("Unexpected create response; inspect before rerunning.")
    print(f"Created draft {tag} from RELEASE_DRAFT.md; publication remains manual.")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        # Do not log API response bodies or authorization headers.
        sys.exit(f"Release API failed (HTTP {error.code}); no existing release was edited.")
    except ReleaseError as error:
        sys.exit(f"Release draft preparation failed: {error}")
    except (OSError, ValueError) as error:
        # HTTP-client exceptions can embed a malformed Authorization value.
        # Keep diagnostics useful without printing arbitrary exception text.
        sys.exit(f"Release draft preparation failed ({type(error).__name__}); check notes/API before rerunning.")
