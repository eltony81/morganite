.PHONY: install test fmt lint build clean

install:
	shards install

test:
	crystal spec

fmt:
	crystal tool format

fmt-check:
	crystal tool format --check

lint:
	./bin/ameba

build:
	crystal build src/morganite.cr -o bin/morganite --release

clean:
	rm -rf bin/morganite bin/morganite-web .shards lib
