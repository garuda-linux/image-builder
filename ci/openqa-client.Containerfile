# openqa-cli alone, for the openqa:<edition> CI jobs (ci/openqa-gate.sh).
# hadolint ignore=DL3007
FROM registry.opensuse.org/opensuse/tumbleweed:latest

LABEL org.opencontainers.image.title="garuda openQA client" \
      org.opencontainers.image.source="https://gitlab.com/garuda-linux/tools/image-builder"

# Tumbleweed is rolling, so package versions cannot be pinned
# hadolint ignore=DL3037
RUN zypper -n install --no-recommends openQA-client gawk \
    && zypper -n clean --all \
    && openqa-cli --help >/dev/null
