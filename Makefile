.PHONY: install test fmt lint build docker-build clean

install:
	shards install

test:
	crystal spec

fmt:
	crystal tool format

fmt-check:
	crystal tool format --check

lint:
	crystal run bin/ameba.cr

build:
	crystal build src/morganite/cli_main.cr -o bin/morganite --release

# Experimental HTTP/3 Fetch (docs/jqcp_conformance.md) is compile-time
# opt-in: quic.cr needs OpenSSL's native QUIC API (3.5+), which the default
# build doesn't require. Needs OpenSSL >= 3.5 on the build machine.
build-http3:
	crystal build -Dmorganite_http3 src/morganite/cli_main.cr -o bin/morganite --release

build-static:
	./scripts/build_static.sh

docker-build:
	docker build -t morganite:latest .

clean:
	rm -rf bin/morganite bin/morganite-web .shards lib
