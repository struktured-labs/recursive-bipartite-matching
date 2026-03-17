# Dockerfile for distributed MCCFR training on AWS spot instances.
#
# Builds the OCaml project inside a container with all dependencies.
# The entrypoint runs a configurable number of MCCFR iterations and
# saves the resulting strategy file.
#
# Build:
#   docker build -t rbm-trainer -f scripts/cloud/Dockerfile .
#
# Run locally (test):
#   docker run --rm -v $(pwd)/results:/output rbm-trainer \
#     --iterations 100000 --buckets 20 --output /output/strategy_worker0.dat
#
# Run on EC2 (training + S3 upload):
#   docker run --rm \
#     -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
#     -e S3_BUCKET=my-rbm-strategies -e WORKER_ID=0 \
#     rbm-trainer --iterations 500000 --buckets 20

FROM ocaml/opam:ubuntu-24.04-ocaml-5.2

# Install system dependencies
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libgmp-dev \
    python3-pip \
    curl \
    jq \
    unzip \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/aws /tmp/awscliv2.zip

# Switch to opam user for package installation
USER opam
WORKDIR /home/opam

# Install OCaml dependencies via opam
RUN opam update && opam install -y \
    core \
    core_unix \
    ppx_jane \
    domainslib \
    yojson \
    dune \
  && opam clean -a -c -s --logs

# Copy project source
COPY --chown=opam:opam . /home/opam/rbm
WORKDIR /home/opam/rbm

# Build the project
RUN opam exec -- dune build 2>&1

# Verify the key binaries exist
RUN opam exec -- dune exec -- rbm-merge-strategies --help 2>&1 | head -1 || true
RUN test -f _build/default/bin/slumbot_client.exe
RUN test -f _build/default/bin/merge_strategies.exe

# Copy the training entrypoint script
COPY --chown=opam:opam scripts/cloud/entrypoint.sh /home/opam/entrypoint.sh
RUN chmod +x /home/opam/entrypoint.sh

ENTRYPOINT ["/home/opam/entrypoint.sh"]
CMD ["--iterations", "100000", "--buckets", "20"]
