#!/usr/bin/env python3
"""Edits and checks Catalog/catalog.json when Linux bases are published.

publish-image.sh, sign-catalog.sh, verify-catalog.sh, and the "Publish Linux Base" workflow use it,
so the catalog is always written the same way as update_catalog.py writes it and diffs stay small.

Images are published with the catalog version that first lists them: all builds for catalog
version N are assets of one release, catalog-vN, and each image's catalogVersion is N. Published
builds are never replaced: environments remember the version they were created with, so a new
build of a published base comes with the next catalog version. The catalog lists only the newest
build of each base, though, so environments created on an earlier one can't download it again;
that's why building a published base again takes --rebuild.

Usage: catalog_release.py [--catalog <file>] next-version [--rebuild] <id>
           prints the catalogVersion a new build of <id> gets: the next catalog version
           (for a published base only with --rebuild)
       catalog_release.py [--catalog <file>] release-tag
           prints the release that holds the builds for the next catalog version (catalog-v<N>)
       catalog_release.py [--catalog <file>] published-version <id> <sha256>
           prints the base's catalogVersion if the catalog lists the build with this checksum
           already, else nothing
       catalog_release.py [--catalog <file>] set-source <id> <version> <url> <sha256> <size>
           enters a published build: the base's catalogVersion, source, and downloadSizeBytes
       catalog_release.py [--catalog <file>] finish
           raises the catalog's catalogVersion (apps only install newer catalogs) and sets publishedAt
       catalog_release.py [--catalog <file>] check
           checks what apps rely on; sign-catalog.sh and verify-catalog.sh run it
       catalog_release.py [--catalog <file>] newer-than <previous catalog>
           fails if the catalog differs from the previous one without a higher catalogVersion,
           which apps would ignore; the "Catalog" workflow runs it

<file> defaults to Catalog/catalog.json. Runs with the Python 3.9 of macOS.
"""
import argparse
import datetime
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Catalog/catalog.json"
# Where publish-image.sh uploads builds; sources there must name the base's own release.
RELEASES = "https://github.com/morzan1001/Runfern/releases/download/"
# Apps refuse larger catalog downloads (CatalogStore.fetch).
MAX_CATALOG_BYTES = 4 * 1024 * 1024
PACKAGE_FORMATS = {"tar.gz", "tar.xz", "zip"}
SHA256 = re.compile(r"[0-9a-fA-F]{64}")
# The app decodes publishedAt as ISO 8601 without fractional seconds.
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


class CatalogError(Exception):
    pass


def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def dump(catalog):
    return json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"


def save(path, catalog):
    pathlib.Path(path).write_text(dump(catalog), encoding="utf-8")


def base_image(catalog, image_id):
    for image in catalog["baseImages"]:
        if image["id"] == image_id:
            return image
    known = ", ".join(image["id"] for image in catalog["baseImages"])
    raise CatalogError(f"the catalog has no base {image_id}; it lists {known}.")


def release_tag(version):
    return f"catalog-v{version}"


def release_url(image_id, version):
    return f"{RELEASES}{release_tag(version)}/{image_id}.runfernimage"


def is_count(value, minimum=1):
    # bool is an int in Python, but not in the JSON the app decodes.
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def is_https(url):
    return isinstance(url, str) and url.startswith("https://") and len(url) > 8 and not re.search(r"\s", url)


def next_version(catalog, image_id, rebuild=False):
    image = base_image(catalog, image_id)
    if image.get("source") and not rebuild:
        raise CatalogError(
            f"{image_id} is published as version {image['catalogVersion']} already. The catalog lists one build "
            f"per base, so a new build takes its place there, and environments created on version "
            f"{image['catalogVersion']} can't download their base anymore. Build it again only on purpose: "
            f"--rebuild (in the workflow: rebuild).")
    return max(catalog["catalogVersion"], image["catalogVersion"]) + 1


def published_version(catalog, image_id, sha256):
    """The base's catalogVersion if its source is the build with this checksum, else None."""
    image = base_image(catalog, image_id)
    source = image.get("source")
    if isinstance(source, dict) and str(source.get("sha256", "")).lower() == sha256.lower():
        return image["catalogVersion"]
    return None


def set_source(catalog, image_id, version, url, sha256, size):
    image = base_image(catalog, image_id)
    if not is_count(version):
        raise CatalogError(f"the version of {image_id} must be a positive number, not {version!r}.")
    lowest = image["catalogVersion"] + 1 if image.get("source") else 1
    if version < lowest:
        raise CatalogError(f"{image_id} is published as version {image['catalogVersion']} already; "
                           f"published builds are never replaced, so a new build needs version "
                           f"{lowest} or higher.")
    if not is_https(url):
        raise CatalogError(f"the address of {image_id} must be an https URL, not {url!r}.")
    if not isinstance(sha256, str) or not SHA256.fullmatch(sha256):
        raise CatalogError(f"the checksum of {image_id} must be 64 hexadecimal digits (SHA-256).")
    if not is_count(size):
        raise CatalogError(f"the size of {image_id} must be a positive number of bytes, not {size!r}.")
    image["catalogVersion"] = version
    image["source"] = {"url": url, "sha256": sha256.lower()}
    image["downloadSizeBytes"] = size
    problems = image_problems(image)
    if problems:
        raise CatalogError(" ".join(problems))


def version_problem(data, previous_data):
    """Why apps would ignore the catalog `data` (bytes) once they have `previous_data`: they install
    only catalogs with a higher catalogVersion, so every change needs one. None if there's no problem."""
    if data == previous_data:
        return None
    version, previous = json.loads(data)["catalogVersion"], json.loads(previous_data).get("catalogVersion")
    if is_count(previous) and not (is_count(version) and version > previous):
        return (f"the catalog differs from the previous one but has catalogVersion {version!r}, not more than "
                f"{previous}: apps that have the previous one would ignore it. Raise it (catalog_release.py "
                f"finish) and sign again (sign-catalog.sh).")
    return None


def finish(catalog, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    catalog["catalogVersion"] += 1
    catalog["publishedAt"] = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# MARK: Checking

def missing(item, name, keys):
    return [f"{name} lacks {key}." for key in keys if key not in item]


def image_problems(image):
    name = image.get("id", "a base")
    problems = missing(image, name, ["id", "distribution", "release", "architecture", "catalogVersion",
                                     "downloadSizeBytes", "supportedToolchains"])
    if problems:
        return problems
    if not is_count(image["catalogVersion"]):
        problems.append(f"{name} needs a positive catalogVersion.")
    if not is_count(image["downloadSizeBytes"]):
        problems.append(f"{name} needs a positive downloadSizeBytes.")
    source = image.get("source")
    if source is None:
        return problems
    if not isinstance(source, dict) or not is_https(source.get("url")) \
            or not isinstance(source.get("sha256"), str) or not SHA256.fullmatch(source["sha256"]):
        problems.append(f"{name} needs an https URL and a SHA-256 checksum (64 hexadecimal digits).")
    elif source["url"].startswith(RELEASES) and source["url"] != release_url(image["id"], image["catalogVersion"]):
        # Environments record the image's catalogVersion; it must name the build they download.
        problems.append(f"{name} has catalogVersion {image['catalogVersion']}, but its source is "
                        f"{source['url']} instead of {release_url(image['id'], image['catalogVersion'])}.")
    return problems


def package_problems(package, name):
    problems = missing(package, f"a package of {name}",
                       ["url", "sha256", "format", "sizeBytes", "installRoot", "stripComponents"])
    if problems:
        return problems
    if not is_https(package["url"]) or not isinstance(package["sha256"], str) \
            or not SHA256.fullmatch(package["sha256"]):
        problems.append(f"a package of {name} needs an https URL and a SHA-256 checksum (64 hexadecimal digits).")
    if package["format"] not in PACKAGE_FORMATS:
        problems.append(f"a package of {name} has the unknown format {package['format']!r}.")
    if not is_count(package["sizeBytes"]) or not is_count(package["stripComponents"], minimum=0):
        problems.append(f"a package of {name} needs a positive sizeBytes and a stripComponents of 0 or more.")
    return problems


def problems(catalog, size):
    """Everything that would make apps reject the catalog or download something unverified."""
    found = missing(catalog, "the catalog", ["format", "catalogVersion", "publishedAt", "baseImages", "toolchains"])
    if found:
        return found
    if size >= MAX_CATALOG_BYTES:
        found.append(f"the catalog has {size} bytes; apps download at most {MAX_CATALOG_BYTES - 1}.")
    if catalog["format"] != 1:
        found.append(f"the catalog has format {catalog['format']!r}; apps read format 1.")
    if not is_count(catalog["catalogVersion"]):
        found.append("the catalog needs a positive catalogVersion.")
    if not isinstance(catalog["publishedAt"], str) or not TIMESTAMP.fullmatch(catalog["publishedAt"]):
        found.append(f"publishedAt must look like 2026-10-26T09:55:17Z, not {catalog['publishedAt']!r}.")
    toolchain_ids = set()
    for toolchain in catalog["toolchains"]:
        name = toolchain.get("id", "a toolchain")
        found += missing(toolchain, name, ["id", "family", "familyName", "version", "revision", "summaries",
                                           "estimatedSizeBytes", "packages", "commands", "environment", "extensions"])
        if name in toolchain_ids:
            found.append(f"{name} is listed twice.")
        toolchain_ids.add(name)
        if not toolchain.get("packages"):
            found.append(f"{name} has no packages.")
        for package in toolchain.get("packages") or []:
            found += package_problems(package, name)
    image_ids = set()
    for image in catalog["baseImages"]:
        found += image_problems(image)
        if image.get("id") in image_ids:
            found.append(f"{image['id']} is listed twice.")
        image_ids.add(image.get("id"))
        unknown = [t for t in image.get("supportedToolchains", []) if t not in toolchain_ids]
        if unknown:
            found.append(f"{image.get('id')} names unknown toolchains: {', '.join(unknown)}.")
    return found


def main(arguments=None):
    parser = argparse.ArgumentParser(description="Edits and checks the Runfern catalog for publishing Linux bases.")
    parser.add_argument("--catalog", default=str(CATALOG), help="catalog file (default: Catalog/catalog.json)")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("next-version", help="prints the catalogVersion a new build of a base gets")
    command.add_argument("--rebuild", action="store_true", help="also for a base that is published already")
    command.add_argument("id")
    command = commands.add_parser("published-version", help="prints the version if the catalog lists this build")
    command.add_argument("id")
    command.add_argument("sha256")
    command = commands.add_parser("set-source", help="enters a published build of a base")
    command.add_argument("id")
    command.add_argument("version", type=int)
    command.add_argument("url")
    command.add_argument("sha256")
    command.add_argument("size", type=int)
    commands.add_parser("release-tag", help="prints the release for builds of the next catalog version")
    commands.add_parser("finish", help="raises catalogVersion and sets publishedAt to now")
    commands.add_parser("check", help="checks the catalog's shape")
    command = commands.add_parser("newer-than", help="checks that a changed catalog has a higher catalogVersion")
    command.add_argument("previous")
    options = parser.parse_args(arguments)

    try:
        catalog = load(options.catalog)
        if options.command == "next-version":
            print(next_version(catalog, options.id, options.rebuild))
        elif options.command == "published-version":
            version = published_version(catalog, options.id, options.sha256)
            if version is not None:
                print(version)
        elif options.command == "set-source":
            set_source(catalog, options.id, options.version, options.url, options.sha256, options.size)
            save(options.catalog, catalog)
        elif options.command == "newer-than":
            # Bytes: the signature covers them, so any change at all counts.
            data, previous = pathlib.Path(options.catalog).read_bytes(), pathlib.Path(options.previous).read_bytes()
            problem = version_problem(data, previous)
            if problem:
                raise CatalogError(problem)
            print("The catalog is unchanged." if data == previous else
                  f"Catalog version {catalog['catalogVersion']} follows {json.loads(previous).get('catalogVersion')!r}.")
        elif options.command == "release-tag":
            print(release_tag(catalog["catalogVersion"] + 1))
        elif options.command == "finish":
            finish(catalog)
            save(options.catalog, catalog)
            print(f"Catalog version {catalog['catalogVersion']}, published {catalog['publishedAt']}")
        else:
            found = problems(catalog, pathlib.Path(options.catalog).stat().st_size)
            if found:
                raise CatalogError("\n       ".join(found))
            published = [f"{i['id']} v{i['catalogVersion']}" for i in catalog["baseImages"] if i.get("source")]
            print(f"Catalog version {catalog['catalogVersion']}, published {catalog['publishedAt']}; "
                  f"published bases: {', '.join(published) or 'none'}")
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        # ValueError covers malformed JSON; the others a catalog of the wrong shape.
        sys.exit(f"error: {options.catalog} can't be used: {error!r}")
    except CatalogError as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
