FROM golang:1.24-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client openssh-server shellcheck sudo \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash remote \
    && echo 'remote:docker-test-only' | chpasswd

WORKDIR /src
COPY . .
CMD ["bash", "test/docker-test.sh"]
