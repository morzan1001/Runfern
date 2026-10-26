#!/usr/bin/env python3
"""Pins the prebuilt toolchain archives in Catalog/catalog.json.

Resolves the current upstream builds for linux/arm64, records URL, SHA-256, and size, and keeps
the human-written parts of each profile (name, summaries, extensions). Re-sign the catalog
afterwards with Tools/Catalog/sign-catalog.sh.

Usage: resolve_toolchains.py [path/to/catalog.json]
"""
import json
import pathlib
import sys
import urllib.request

CATALOG = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                       pathlib.Path(__file__).resolve().parents[2] / "Catalog/catalog.json")
HEADERS = {"User-Agent": "Runfern-catalog"}
GRADLE_VERSION = "8.10.2"


def fetch(url):
    headers = dict(HEADERS)
    if url.startswith("https://api.github.com/"):
        headers["Accept"] = "application/vnd.github+json"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers)).read()


def content_length(url):
    request = urllib.request.Request(url, method="HEAD", headers=HEADERS)
    return int(urllib.request.urlopen(request).headers["Content-Length"])


def python():
    release = json.loads(fetch("https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"))
    sums = {}
    for asset in release["assets"]:
        if asset["name"] == "SHA256SUMS":
            for line in fetch(asset["browser_download_url"]).decode().splitlines():
                digest, name = line.split()
                sums[name] = digest
    asset = next(a for a in release["assets"]
                 if a["name"].startswith("cpython-3.12.")
                 and a["name"].endswith("aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"))
    root = "/opt/runfern/python-3"
    return {
        "packages": [{"url": asset["browser_download_url"], "sha256": sums[asset["name"]], "format": "tar.gz",
                      "sizeBytes": asset["size"], "installRoot": root, "stripComponents": 1}],
        "commands": {name: f"{root}/bin/{target}" for name, target in
                     {"python": "python3", "python3": "python3", "pip": "pip3", "pip3": "pip3"}.items()},
        "environment": {},
    }


def node():
    base = "https://nodejs.org/dist/latest-v22.x/"
    line = next(l for l in fetch(base + "SHASUMS256.txt").decode().splitlines() if l.endswith("linux-arm64.tar.gz"))
    digest, name = line.split()
    url = base.replace("latest-v22.x", name.split("-")[1]) + name
    root = "/opt/runfern/nodejs-22"
    return {
        "packages": [{"url": url, "sha256": digest, "format": "tar.gz", "sizeBytes": content_length(url),
                      "installRoot": root, "stripComponents": 1}],
        "commands": {tool: f"{root}/bin/{tool}" for tool in ("node", "npm", "npx", "corepack")},
        "environment": {},
    }


def java():
    package = json.loads(fetch("https://api.adoptium.net/v3/assets/latest/21/hotspot"
                               "?architecture=aarch64&image_type=jdk&os=linux&vendor=eclipse"))[0]["binary"]["package"]
    gradle = f"https://services.gradle.org/distributions/gradle-{GRADLE_VERSION}-bin.zip"
    jdk_root, gradle_root = "/opt/runfern/jdk-21", "/opt/runfern/gradle"
    commands = {tool: f"{jdk_root}/bin/{tool}" for tool in ("java", "javac", "jar", "jshell")}
    commands["gradle"] = f"{gradle_root}/bin/gradle"
    return {
        "packages": [
            {"url": package["link"], "sha256": package["checksum"], "format": "tar.gz", "sizeBytes": package["size"],
             "installRoot": jdk_root, "stripComponents": 1},
            {"url": gradle, "sha256": fetch(gradle + ".sha256").decode().strip(), "format": "zip",
             "sizeBytes": content_length(gradle), "installRoot": gradle_root, "stripComponents": 1},
        ],
        "commands": commands,
        "environment": {"JAVA_HOME": jdk_root},
    }


RESOLVERS = {"python-3": python, "nodejs-22": node, "java-21": java}


def main():
    catalog = json.loads(CATALOG.read_text())
    for profile in catalog["toolchains"]:
        resolved = RESOLVERS[profile["id"]]()
        profile.update(resolved)
        download = sum(p["sizeBytes"] for p in resolved["packages"])
        # Unpacked archives take roughly three times their compressed size.
        profile["estimatedSizeBytes"] = download * 3
        print(profile["id"], [p["url"].rsplit("/", 1)[-1] for p in resolved["packages"]])
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
