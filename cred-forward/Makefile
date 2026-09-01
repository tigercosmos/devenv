SHELL := /bin/sh
PLATFORMS := darwin/amd64 darwin/arm64 linux/amd64 linux/arm64

.PHONY: test build clean docker-test

test:
	go test ./...

build: clean
	@set -eu; \
	for platform in $(PLATFORMS); do \
		os=$${platform%/*}; arch=$${platform#*/}; out=dist/$$os-$$arch; \
		mkdir -p "$$out"; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -o "$$out/cred-agent" ./cmd/cred-agent; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -o "$$out/cred-client" ./cmd/cred-client; \
	done

docker-test:
	docker build --progress=plain -f test/Dockerfile -t cred-forward-test .
	docker run --rm cred-forward-test

clean:
	rm -rf dist
