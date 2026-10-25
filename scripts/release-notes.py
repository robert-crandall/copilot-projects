#!/usr/bin/env python3
"""Freeze the changes in an exact build, without publishing or changing refs."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


MAX_BYTES = 256 * 1024
PR_NUMBER = re.compile(r"^merge pull request #?(\d+)\b|\(#(\d+)\)$", re.IGNORECASE)


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], text=True, encoding="utf-8"
    ).strip()


def escape(text):
    return re.sub(r"([\\`*\[\]()_~])", r"\\\1", " ".join(text.split()))


def category(title, labels):
    labels = {label.lower() for label in labels}
    if labels & {"bug", "fix", "bugfix"} or re.match(
        r"^(fix(?:es)?|prevent|correct|repair|restore|ignore|debounce)\b",
        title, re.IGNORECASE
    ):
        return "Fixes"
    if labels & {"enhancement", "feature"} or re.match(
        r"^(feat|add|enable|support|introduce|improve|extend|implement)\b",
        title, re.IGNORECASE
    ):
        return "Features and improvements"
    return "Other changes"


def pull_request(repository, number, revision):
    raw = subprocess.check_output(
        ["gh", "api", f"repos/{repository}/pulls/{number}"], text=True
    )
    pr = json.loads(raw)
    if not pr.get("merged_at") or pr.get("merge_commit_sha") != revision:
        raise ValueError(f"PR {number} does not identify merged commit {revision}")
    title = pr.get("title")
    if not isinstance(title, str) or not title.strip():
        raise ValueError(f"PR {number} has no title")
    return title, [label["name"] for label in pr.get("labels", [])]


def host_pin(root, revision):
    # Only copy public dependency context into companion notes, never the reverse.
    files = git(root, "ls-tree", "--name-only", revision, "Package.resolved").splitlines()
    if not files:
        return None
    resolved = json.loads(git(root, "show", f"{revision}:Package.resolved"))
    for pin in resolved.get("pins", []):
        if pin.get("location", "").removesuffix(".git") == "https://github.com/sirfergy/copilot-projects":
            value = pin["state"]["revision"]
            if not re.fullmatch(r"[0-9a-f]{40}", value):
                raise ValueError("Invalid public host pin")
            return value
    return None


def plain_text(sections):
    text = "\n\n".join(
        heading + "\n" + "\n".join("- " + title for title, _ in changes)
        for heading, changes in sections.items() if changes
    )
    if len(text.encode("utf-16-le")) // 2 <= 4000:
        return text
    suffix = "\n\nMore changes are available in What's New in the app."
    available = 4000 - len(suffix.encode("utf-16-le")) // 2
    prefix = text.encode("utf-16-le")[:available * 2].decode("utf-16-le", errors="ignore")
    return prefix.rsplit("\n", 1)[0] + suffix


def markdown_change(title, url):
    text = "- " + escape(title)
    if not url:
        return text
    reference = (
        "#" + url.rsplit("/", 1)[1] if "/pull/" in url else
        "View changes" if "/compare/" in url else url.rsplit("/", 1)[1][:7]
    )
    return f"{text} ([{reference}]({url}))"


def generate(root, repository, previous, version, build):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", repository):
        raise ValueError("Repository must be owner/name")
    if not version or not build:
        raise ValueError("Version and build are required")
    revision = git(root, "rev-parse", "HEAD^{commit}")
    if previous:
        previous = git(root, "rev-parse", "--verify", f"{previous}^{{commit}}")
        subprocess.run(
            ["git", "-C", str(root), "merge-base", "--is-ancestor", previous, revision],
            check=True
        )
    history = git(
        root, "log", "--first-parent", "--reverse", "--format=%H%x09%s",
        f"{previous}..{revision}" if previous else revision
    )
    sections = {"Features and improvements": [], "Fixes": [], "Other changes": []}
    for line in history.splitlines():
        sha, subject = line.split("\t", 1)
        match = PR_NUMBER.search(subject)
        if match:
            number = next(value for value in match.groups() if value)
            title, labels = pull_request(repository, number, sha)
            url = f"https://github.com/{repository}/pull/{number}"
        else:
            title, labels = subject, []
            url = f"https://github.com/{repository}/commit/{sha}"
        title = " ".join(title.split())
        if not title or re.match(r"^(co-authored-by|copilot-session|signed-off-by):", title, re.I):
            raise ValueError(f"Commit {sha} has no usable change title")
        sections[category(title, labels)].append((title, url))
    if not any(sections.values()):
        sections["Other changes"].append(("No source changes since the previous build.", None))
    if previous:
        old_host, new_host = host_pin(root, previous), host_pin(root, revision)
        if old_host and new_host and old_host != new_host:
            sections["Desktop host changes"] = [(
                "View the desktop host changes included in this build",
                f"https://github.com/sirfergy/copilot-projects/compare/{old_host}...{new_host}"
            )]
    markdown = "\n\n".join(
        "## " + heading + "\n\n" + "\n".join(
            markdown_change(title, url)
            for title, url in changes
        ) for heading, changes in sections.items() if changes
    ) + "\n"
    document = {
        "schemaVersion": 1, "repository": repository, "version": version, "build": build,
        "sourceRevision": revision, "markdown": markdown, "plainText": plain_text(sections),
    }
    validate(document, version, build)
    return document


def validate(document, version, build):
    if document.get("schemaVersion") != 1:
        raise ValueError("Unsupported release-notes schema")
    if document.get("version") != version or document.get("build") != build:
        raise ValueError("Release notes do not match this version and build")
    if not re.fullmatch(r"[0-9a-f]{40}", document.get("sourceRevision", "")):
        raise ValueError("Invalid release-notes source revision")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*", document.get("repository", "")):
        raise ValueError("Invalid release-notes repository")
    for key in ("markdown", "plainText"):
        if not isinstance(document.get(key), str) or not document[key].strip():
            raise ValueError(f"Release notes require {key}")
    if len(document["plainText"].encode("utf-16-le")) // 2 > 4000:
        raise ValueError("TestFlight notes exceed 4000 characters")
    if len(json.dumps(document, ensure_ascii=False).encode("utf-8")) > MAX_BYTES:
        raise ValueError("Release notes exceed the bundled size limit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("generate")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--previous")
    create.add_argument("--output", type=Path, required=True)
    check = sub.add_parser("validate")
    check.add_argument("--file", type=Path, required=True)
    check.add_argument("--markdown", action="store_true")
    for command in (create, check):
        command.add_argument("--version", required=True)
        command.add_argument("--build", required=True)
    args = parser.parse_args()
    if args.command == "generate":
        document = generate(args.root, args.repository, args.previous, args.version, args.build)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(document, ensure_ascii=False) + "\n", encoding="utf-8")
    else:
        if args.file.stat().st_size > MAX_BYTES:
            raise ValueError("Release notes exceed the bundled size limit")
        document = json.loads(args.file.read_text(encoding="utf-8"))
        validate(document, args.version, args.build)
        if args.markdown:
            print(document["markdown"], end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: release notes: {error}", file=sys.stderr)
        sys.exit(1)
