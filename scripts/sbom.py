#!/usr/bin/env python3
"""SPDX 2.3 SBOM from a mkosi JSON manifest.

It depends only on the manifest and SOURCE_DATE_EPOCH, so that it stays reproducible.
Usage: sbom <manifest> <image name> <version> >image.spdx.json
"""

import hashlib
import json
import os
import sys
from datetime import UTC, datetime

USAGE = "usage: sbom <manifest> <image name> <version>"


def spdx_id(text):
    return "SPDXRef-" + "".join(c if c.isalnum() or c in ".-" else "-" for c in text)


def document(raw, name, version, epoch):
    manifest = json.loads(raw)
    created = datetime.fromtimestamp(int(epoch), UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    image_id = spdx_id(f"Image-{name}")
    packages = [
        {
            "name": name,
            "SPDXID": image_id,
            "versionInfo": version,
            "supplier": "Organization: Garuda Linux",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "primaryPackagePurpose": "OPERATING-SYSTEM",
        }
    ]
    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": image_id,
        }
    ]
    for p in sorted(manifest.get("packages", []), key=lambda p: p["name"]):
        pid = spdx_id(f"Package-{p['name']}")
        packages.append(
            {
                "name": p["name"],
                "SPDXID": pid,
                "versionInfo": p["version"],
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": (
                            f"pkg:alpm/arch/{p['name']}@{p['version']}?arch={p.get('architecture', 'any')}"
                        ),
                    }
                ],
            }
        )
        relationships.append(
            {
                "spdxElementId": image_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": pid,
            }
        )

    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{name}-{version}",
        # Unique per manifest, and the same for the same manifest
        "documentNamespace": f"https://garudalinux.org/spdx/{name}-{version}-{hashlib.sha256(raw).hexdigest()}",
        "creationInfo": {"created": created, "creators": ["Tool: image-builder"]},
        "packages": packages,
        "relationships": relationships,
    }


def main():
    args = sys.argv[1:4]
    if len(args) < 3 or not all(args):
        sys.exit(USAGE)
    path, name, version = args
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        sys.exit(f"sbom: cannot read {path}: {e}")
    epoch = os.environ.get("SOURCE_DATE_EPOCH") or "0"
    try:
        doc = document(raw, name, version, epoch)
    except ValueError as e:
        sys.exit(f"sbom: {path} is not a JSON manifest: {e}")
    json.dump(doc, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
