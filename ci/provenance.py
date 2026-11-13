#!/usr/bin/env python3
"""Writes an SLSA v1 provenance predicate for cosign attest --type slsaprovenance1.

Usage: ci/provenance.py <output name> >provenance.json
"""

import json
import os
import sys
from datetime import UTC, datetime

USAGE = "usage: ci/provenance.py <output name>"


def image_dependency(image, resolved=""):
    """The builder image as a resolved dependency, with its digest when known."""
    name, _, digest = image.partition("@")
    dependency = {"uri": f"docker://{name}"}
    algorithm, _, value = (digest or resolved).partition(":")

    if value:
        dependency["digest"] = {algorithm: value}

    return dependency


def predicate(output, env):
    project = env("CI_PROJECT_URL", "")
    return {
        "buildDefinition": {
            "buildType": f"{project}/-/blob/{env('CI_COMMIT_SHA', '')}/build.sh",
            "externalParameters": {
                "output": output,
                "source": {
                    "uri": f"git+{project}",
                    "ref": env("CI_COMMIT_REF_NAME", ""),
                    "digest": {"gitCommit": env("CI_COMMIT_SHA", "")},
                },
            },
            "internalParameters": {
                "pipelineSource": env("CI_PIPELINE_SOURCE", ""),
                "sourceDateEpoch": env("SOURCE_DATE_EPOCH", ""),
                "isoCompression": env("ISO_COMPRESSION", ""),
            },
            "resolvedDependencies": [
                {
                    "uri": f"git+{project}@{env('CI_COMMIT_REF_NAME', '')}",
                    "digest": {"gitCommit": env("CI_COMMIT_SHA", "")},
                },
                image_dependency(env("CI_JOB_IMAGE", ""), env("BUILDER_IMAGE_DIGEST", "")),
            ],
        },
        "runDetails": {
            "builder": {"id": f"{env('CI_SERVER_URL', '')}/runners/{env('CI_RUNNER_ID', '')}"},
            "metadata": {
                "invocationId": env("CI_JOB_URL", ""),
                "startedOn": env("CI_JOB_STARTED_AT", ""),
                "finishedOn": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
        },
    }


def main():
    if len(sys.argv) < 2 or not sys.argv[1]:
        sys.exit(USAGE)

    json.dump(predicate(sys.argv[1], os.environ.get), sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
