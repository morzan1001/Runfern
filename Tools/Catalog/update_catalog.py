#!/usr/bin/env python3
"""Writes Catalog/catalog.json: the Linux bases and the toolchain versions Runfern offers.

The bases and toolchains are defined below. For each toolchain version the current upstream build
for linux/arm64 is resolved and pinned with its URL, SHA-256 checksum, and size. Published image
sources already in the catalog are kept. Sign the catalog afterwards with sign-catalog.sh.

Usage: update_catalog.py [--version N]     N is the catalogVersion to write (default: unchanged)
"""
import datetime
import hashlib
import json
import pathlib
import re
import sys
import tomllib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Catalog/catalog.json"
HEADERS = {"User-Agent": "Runfern-catalog"}

# Linux bases. `swift` names the swift.org platform build that matches the base, if any.
BASES = [
    {"id": "debian-12-arm64", "distribution": "Debian", "release": "12", "swift": ("debian12", "debian12")},
    {"id": "debian-13-arm64", "distribution": "Debian", "release": "13", "swift": ("debian13", "debian13")},
    {"id": "ubuntu-24.04-arm64", "distribution": "Ubuntu", "release": "24.04", "swift": ("ubuntu2404", "ubuntu24.04")},
    {"id": "ubuntu-26.04-arm64", "distribution": "Ubuntu", "release": "26.04", "swift": ("ubuntu2604", "ubuntu26.04")},
    {"id": "fedora-44-arm64", "distribution": "Fedora", "release": "44", "swift": ("fedora41", "fedora41")},
]
# Rough download sizes until an image is published; publish-image.sh enters the real size.
ESTIMATED_IMAGE_BYTES = 1_200_000_000


def fetch(url):
    headers = dict(HEADERS)
    if url.startswith("https://api.github.com/"):
        headers["Accept"] = "application/vnd.github+json"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60).read()


def fetch_json(url):
    return json.loads(fetch(url))


def head_size(url):
    request = urllib.request.Request(url, method="HEAD", headers=HEADERS)
    return int(urllib.request.urlopen(request, timeout=60).headers["Content-Length"])


def download_digest(url):
    """SHA-256 and size of a file whose publisher offers no SHA-256 checksum."""
    digest, size = hashlib.sha256(), 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=120) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def package(url, sha256, size, root, strip, kind=None):
    kind = kind or ("zip" if url.endswith(".zip") else "tar.xz" if url.endswith(".tar.xz") else "tar.gz")
    return {"url": url, "sha256": sha256, "format": kind, "sizeBytes": size, "installRoot": root,
            "stripComponents": strip}


def github_release(repository):
    return fetch_json(f"https://api.github.com/repos/{repository}/releases/latest")


# MARK: Toolchains

def python3():
    release = github_release("astral-sh/python-build-standalone")
    sums = {}
    for asset in release["assets"]:
        if asset["name"] == "SHA256SUMS":
            for line in fetch(asset["browser_download_url"]).decode().splitlines():
                digest, name = line.split()
                sums[name] = digest
    pattern = re.compile(r"cpython-3\.(\d+)\.(\d+)\+\d+-aarch64-unknown-linux-gnu-install_only_stripped\.tar\.gz")
    candidates = [(int(m[1]), int(m[2]), a) for a in release["assets"] if (m := pattern.fullmatch(a["name"]))]
    minor, _, asset = max(candidates, key=lambda c: (c[0], c[1]))
    root = "/opt/runfern/python-3"
    return f"3.{minor}", [package(asset["browser_download_url"], sums[asset["name"]], asset["size"], root, 1)], \
        {name: f"{root}/bin/{target}" for name, target in
         {"python": "python3", "python3": "python3", "pip": "pip3", "pip3": "pip3"}.items()}, {}


def nodejs(major):
    def resolve():
        base = f"https://nodejs.org/dist/latest-v{major}.x/"
        digest, name = next(l.split() for l in fetch(base + "SHASUMS256.txt").decode().splitlines()
                            if l.endswith("linux-arm64.tar.gz"))
        version = name.split("-")[1]
        url = f"https://nodejs.org/dist/{version}/{name}"
        root = f"/opt/runfern/nodejs-{major}"
        return str(major), [package(url, digest, head_size(url), root, 1)], \
            {tool: f"{root}/bin/{tool}" for tool in ("node", "npm", "npx", "corepack")}, {}
    return resolve


def gradle():
    current = fetch_json("https://services.gradle.org/versions/current")
    url = current["downloadUrl"]
    return package(url, fetch(current["checksumUrl"]).decode().strip(), head_size(url), "/opt/runfern/gradle", 1)


def java(major):
    def resolve():
        jdk = fetch_json(f"https://api.adoptium.net/v3/assets/latest/{major}/hotspot"
                         "?architecture=aarch64&image_type=jdk&os=linux&vendor=eclipse")[0]["binary"]["package"]
        root = f"/opt/runfern/jdk-{major}"
        commands = {tool: f"{root}/bin/{tool}" for tool in ("java", "javac", "jar", "jshell")}
        commands["gradle"] = "/opt/runfern/gradle/bin/gradle"
        return str(major), [package(jdk["link"], jdk["checksum"], jdk["size"], root, 1), gradle()], \
            commands, {"JAVA_HOME": root}
    return resolve


def go():
    release = next(r for r in fetch_json("https://go.dev/dl/?mode=json") if r["stable"])
    file = next(f for f in release["files"] if f["os"] == "linux" and f["arch"] == "arm64" and f["kind"] == "archive")
    root = "/opt/runfern/go"
    return release["version"].removeprefix("go"), \
        [package(f"https://go.dev/dl/{file['filename']}", file["sha256"], file["size"], root, 1)], \
        {tool: f"{root}/bin/{tool}" for tool in ("go", "gofmt")}, {"GOROOT": root}


def rust():
    channel = tomllib.loads(fetch("https://static.rust-lang.org/dist/channel-rust-stable.toml").decode())
    target = "aarch64-unknown-linux-gnu"
    root = "/opt/runfern/rust"
    packages = []
    # The components share one prefix: rustc and cargo in bin, the standard library in lib/rustlib.
    for component in ("rustc", "rust-std", "cargo", "rustfmt-preview", "clippy-preview"):
        build = channel["pkg"][component]["target"][target]
        packages.append(package(build["xz_url"], build["xz_hash"], head_size(build["xz_url"]), root, 2))
    version = channel["pkg"]["rustc"]["version"].split()[0]
    return version, packages, \
        {tool: f"{root}/bin/{tool}" for tool in ("rustc", "cargo", "rustfmt", "cargo-fmt", "cargo-clippy", "clippy-driver")}, \
        {"CARGO_HOME": "/home/runfern/.cargo"}


def swift(platform_dir, platform_name):
    def resolve():
        version = fetch_json("https://www.swift.org/api/v1/install/releases.json")[-1]["name"]
        tag = f"swift-{version}-RELEASE"
        directory = f"{platform_dir}-aarch64"
        url = f"https://download.swift.org/{tag.lower()}/{directory}/{tag}/{tag}-{platform_name}-aarch64.tar.gz"
        digest, size = download_digest(url)
        root = "/opt/runfern/swift"
        return version, [package(url, digest, size, root, 1)], \
            {tool: f"{root}/usr/bin/{tool}" for tool in ("swift", "swiftc", "sourcekit-lsp")}, {}
    return resolve


def dotnet():
    index = fetch_json("https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json")
    channel = next(r for r in index["releases-index"] if r["release-type"] == "lts" and r["support-phase"] == "active")
    releases = fetch_json(channel["releases.json"])
    sdk = releases["releases"][0]["sdk"]
    file = next(f for f in sdk["files"] if f["rid"] == "linux-arm64" and f["name"].endswith(".tar.gz"))
    digest, size = download_digest(file["url"])
    root = "/opt/runfern/dotnet"
    return channel["channel-version"], [package(file["url"], digest, size, root, 0)], \
        {"dotnet": f"{root}/dotnet"}, {"DOTNET_ROOT": root, "DOTNET_CLI_TELEMETRY_OPTOUT": "1"}


def bun():
    release = github_release("oven-sh/bun")
    asset = next(a for a in release["assets"] if a["name"] == "bun-linux-aarch64.zip")
    sums = next(a for a in release["assets"] if a["name"] == "SHASUMS256.txt")
    digest = next(l.split()[0] for l in fetch(sums["browser_download_url"]).decode().splitlines()
                  if l.endswith(asset["name"]))
    root = "/opt/runfern/bun"
    return release["tag_name"].removeprefix("bun-v"), \
        [package(asset["browser_download_url"], digest, asset["size"], root, 1)], \
        {"bun": f"{root}/bun", "bunx": f"{root}/bun"}, {}


def deno():
    release = github_release("denoland/deno")
    name = "deno-aarch64-unknown-linux-gnu.zip"
    asset = next(a for a in release["assets"] if a["name"] == name)
    checksum = next(a for a in release["assets"] if a["name"] == name + ".sha256sum")
    digest = fetch(checksum["browser_download_url"]).decode().split()[0]
    root = "/opt/runfern/deno"
    return release["tag_name"].removeprefix("v"), \
        [package(asset["browser_download_url"], digest, asset["size"], root, 0)], {"deno": f"{root}/deno"}, {}


def zig():
    index = fetch_json("https://ziglang.org/download/index.json")
    version = max((v for v in index if v != "master"), key=lambda v: [int(p) for p in v.split(".")])
    build = index[version]["aarch64-linux"]
    root = "/opt/runfern/zig"
    return version, [package(build["tarball"], build["shasum"], int(build["size"]), root, 1)], \
        {"zig": f"{root}/zig"}, {}


# Profiles: id, family, family name, summary, extensions, resolver, and the bases that offer it.
ALL = [base["id"] for base in BASES]
TOOLCHAINS = [
    ("python-3", "python", "Python", {"en": "Runtime, pip, and editor support", "de": "Laufzeit, pip und Editorunterstützung"},
     ["ms-python.python"], python3, ALL),
    ("nodejs-24", "nodejs", "Node.js", {"en": "LTS runtime with npm", "de": "LTS-Laufzeit mit npm"}, [], nodejs(24), ALL),
    ("nodejs-26", "nodejs", "Node.js", {"en": "Current runtime with npm", "de": "Aktuelle Laufzeit mit npm"}, [], nodejs(26), ALL),
    ("java-21", "java", "Java", {"en": "JDK (LTS) and Gradle", "de": "JDK (LTS) und Gradle"},
     ["redhat.java", "vscjava.vscode-java-debug"], java(21), ALL),
    ("java-25", "java", "Java", {"en": "JDK (LTS) and Gradle", "de": "JDK (LTS) und Gradle"},
     ["redhat.java", "vscjava.vscode-java-debug"], java(25), ALL),
    ("java-27", "java", "Java", {"en": "Current JDK and Gradle", "de": "Aktuelles JDK und Gradle"},
     ["redhat.java", "vscjava.vscode-java-debug"], java(27), ALL),
    ("go", "go", "Go", {"en": "Compiler and tools", "de": "Compiler und Werkzeuge"}, ["golang.go"], go, ALL),
    ("rust", "rust", "Rust", {"en": "rustc, Cargo, rustfmt, and Clippy", "de": "rustc, Cargo, rustfmt und Clippy"},
     ["rust-lang.rust-analyzer"], rust, ALL),
    ("dotnet", "dotnet", ".NET", {"en": "SDK (LTS) for C# and F#", "de": "SDK (LTS) für C# und F#"},
     ["muhammad-sammy.csharp"], dotnet, ALL),
    ("bun", "bun", "Bun", {"en": "JavaScript runtime, bundler, and package manager", "de": "JavaScript-Laufzeit, Bundler und Paketverwaltung"},
     ["oven.bun-vscode"], bun, ALL),
    ("deno", "deno", "Deno", {"en": "JavaScript and TypeScript runtime", "de": "JavaScript- und TypeScript-Laufzeit"},
     ["denoland.vscode-deno"], deno, ALL),
    ("zig", "zig", "Zig", {"en": "Compiler and build system", "de": "Compiler und Build-System"}, ["ziglang.vscode-zig"], zig, ALL),
] + [
    (f"swift-{base['id'].removesuffix('-arm64')}", "swift", "Swift",
     {"en": "Compiler, Swift Package Manager, and SourceKit-LSP", "de": "Compiler, Swift Package Manager und SourceKit-LSP"},
     ["swiftlang.swift-vscode"], swift(*base["swift"]), [base["id"]])
    for base in BASES if base["swift"]
]


def main():
    previous = json.loads(CATALOG.read_text()) if CATALOG.exists() else {}
    version = int(sys.argv[sys.argv.index("--version") + 1]) if "--version" in sys.argv else previous.get("catalogVersion", 1)
    sources = {image["id"]: image for image in previous.get("baseImages", []) if image.get("source")}

    toolchains = []
    for identifier, family, family_name, summaries, extensions, resolve, bases in TOOLCHAINS:
        display_version, packages, commands, environment = resolve()
        toolchains.append({
            "id": identifier, "family": family, "familyName": family_name, "version": display_version, "revision": 1,
            "summaries": summaries,
            # Unpacked archives take roughly three times their compressed size.
            "estimatedSizeBytes": sum(p["sizeBytes"] for p in packages) * 3,
            "packages": packages, "commands": commands, "environment": environment, "extensions": extensions,
        })
        print(f"{identifier}: {family_name} {display_version}")

    images = []
    for base in BASES:
        image = {"id": base["id"], "distribution": base["distribution"], "release": base["release"],
                 "architecture": "arm64", "catalogVersion": 1, "downloadSizeBytes": ESTIMATED_IMAGE_BYTES,
                 "supportedToolchains": [t[0] for t in TOOLCHAINS if base["id"] in t[6]]}
        if published := sources.get(base["id"]):
            image.update(catalogVersion=published["catalogVersion"], downloadSizeBytes=published["downloadSizeBytes"],
                         source=published["source"])
        images.append(image)

    catalog = {"format": 1, "catalogVersion": version,
               "publishedAt": datetime.datetime.now(datetime.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
               "baseImages": images, "toolchains": toolchains}
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {CATALOG.relative_to(ROOT)} (catalog version {version}); sign it with Tools/Catalog/sign-catalog.sh.")


if __name__ == "__main__":
    main()
