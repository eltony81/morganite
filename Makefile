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
	crystal build src/morganite/cli.cr -o bin/morganite --release

build-static:
	./scripts/build_static.sh

docker-build:
	docker build -t morganite:latest .

clean:
	rm -rf bin/morganite bin/morganite-web .shards lib
