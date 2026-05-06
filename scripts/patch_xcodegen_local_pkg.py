#!/usr/bin/env python3
"""Patch XcodeGen 2.44.1 local-package bug.

Background
----------
XcodeGen 2.44.1 emits an `XCSwiftPackageProductDependency` block for products
that come from a *local-path* package, but it omits the `package = <ref>;`
back-reference that points at the corresponding `XCLocalSwiftPackageReference`.

Command-line `xcodebuild` tolerates the omission (it appears to resolve the
product through `productRef`/`packageProductDependencies` lookup). The Xcode
IDE does NOT — it fails with `Missing package product '<name>'` and refuses
to open the project.

This script idempotently injects the missing back-reference. It is safe to
run repeatedly — if the line is already present it does nothing.

Usage
-----
    patch_xcodegen_local_pkg.py <path/to/.xcodeproj> [<product-name>...]

If no product names are given, the script will scan the file for every
`XCLocalSwiftPackageReference` entry and patch every product whose dependency
block is missing a `package = …;` line that resolves to one of those refs.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


LOCAL_REF_RE = re.compile(
    r"^\s*([A-F0-9]{24})\s*/\*\s*XCLocalSwiftPackageReference\s+\"([^\"]+)\"\s*\*/\s*=\s*\{",
    re.MULTILINE,
)

PRODUCT_BLOCK_RE = re.compile(
    r"(?P<indent>[\t ]*)(?P<uuid>[A-F0-9]{24})\s*/\*\s*(?P<name>[^*]+?)\s*\*/\s*=\s*\{\s*\n"
    r"(?P<body>(?:.*\n)*?)"
    r"(?P=indent)\};",
    re.MULTILINE,
)


def find_local_refs(text: str) -> dict[str, tuple[str, str]]:
    """Return a map of {basename(path): (uuid, path)} for every local-package ref."""
    refs: dict[str, tuple[str, str]] = {}
    for m in LOCAL_REF_RE.finditer(text):
        uuid = m.group(1)
        path = m.group(2)
        basename = path.rsplit("/", 1)[-1]
        refs[basename] = (uuid, path)
    return refs


def patch_product_dependency(text: str, product_uuid: str, product_name: str,
                             ref_uuid: str, ref_path: str) -> tuple[str, bool]:
    """Inject `package = <ref_uuid> /* … */;` into the named product dep block.

    Returns (new_text, changed).
    """
    pattern = re.compile(
        r"(?P<head>(?P<indent>[\t ]*)" + re.escape(product_uuid) +
        r"\s*/\*\s*" + re.escape(product_name) + r"\s*\*/\s*=\s*\{\s*\n"
        r"(?P<bodyindent>[\t ]+)isa\s*=\s*XCSwiftPackageProductDependency\s*;\s*\n)"
        r"(?P<body>(?:(?!" + re.escape(product_uuid) + r").)*?)"  # stop at next product or close
        r"(?P=indent)\};",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        return text, False

    body = m.group("body")
    if "package =" in body:
        # Already patched
        return text, False

    body_indent = m.group("bodyindent")
    inject = f"{body_indent}package = {ref_uuid} /* XCLocalSwiftPackageReference \"{ref_path}\" */;\n"
    new_block = m.group("head") + inject + body + m.group("indent") + "};"
    new_text = text[: m.start()] + new_block + text[m.end():]
    return new_text, True


def discover_orphan_products(text: str) -> list[tuple[str, str]]:
    """Find product-dep blocks missing a `package = …;` line.

    Returns a list of (uuid, productName) tuples.
    """
    section_re = re.compile(
        r"/\*\s*Begin\s+XCSwiftPackageProductDependency\s+section\s*\*/(.*?)"
        r"/\*\s*End\s+XCSwiftPackageProductDependency\s+section\s*\*/",
        re.DOTALL,
    )
    sm = section_re.search(text)
    if not sm:
        return []
    section = sm.group(1)

    block_re = re.compile(
        r"(?P<indent>[\t ]*)(?P<uuid>[A-F0-9]{24})\s*/\*\s*(?P<name>[^*]+?)\s*\*/\s*=\s*\{\s*\n"
        r"(?P<body>(?:[\t ]+[^\n]*\n)+?)"
        r"(?P=indent)\};",
        re.MULTILINE,
    )
    orphans: list[tuple[str, str]] = []
    for bm in block_re.finditer(section):
        body = bm.group("body")
        if "package =" not in body:
            orphans.append((bm.group("uuid"), bm.group("name").strip()))
    return orphans


def patch_file(pbxproj_path: Path, explicit_products: list[str]) -> int:
    text = pbxproj_path.read_text()
    refs = find_local_refs(text)
    if not refs:
        print(f"[patch] no XCLocalSwiftPackageReference entries — nothing to do")
        return 0

    orphans = discover_orphan_products(text)
    if not orphans:
        print(f"[patch] no orphan product deps — already patched")
        return 0

    if explicit_products:
        # Filter orphans to the requested set (by name).
        wanted = set(explicit_products)
        orphans = [(u, n) for (u, n) in orphans if n in wanted]

    if not orphans:
        print(f"[patch] no orphan product deps match requested products — nothing to do")
        return 0

    # If there is exactly one local-package ref, point all orphans at it.
    # Otherwise we'd need a deterministic name-mapping — bail loudly.
    if len(refs) > 1:
        print(f"[patch] error: multiple local-package refs found ({list(refs)});"
              f" deterministic mapping not implemented", file=sys.stderr)
        return 2

    (_ref_basename, (ref_uuid, ref_path)) = next(iter(refs.items()))
    print(f"[patch] using local-pkg ref {ref_uuid} -> {ref_path}")

    changed_any = False
    for (uuid, name) in orphans:
        new_text, changed = patch_product_dependency(text, uuid, name, ref_uuid, ref_path)
        if changed:
            text = new_text
            changed_any = True
            print(f"[patch] injected `package =` for product {name} ({uuid})")

    if changed_any:
        pbxproj_path.write_text(text)
        print(f"[patch] wrote {pbxproj_path}")
    else:
        print(f"[patch] no changes needed")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1
    proj_arg = Path(argv[1])
    if proj_arg.suffix == ".xcodeproj":
        pbxproj = proj_arg / "project.pbxproj"
    else:
        pbxproj = proj_arg
    if not pbxproj.exists():
        print(f"[patch] error: {pbxproj} does not exist", file=sys.stderr)
        return 1
    explicit_products = argv[2:]
    return patch_file(pbxproj, explicit_products)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
