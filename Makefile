.PHONY: build run test clean watch

build:
	zig build

run:
	zig build run

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache

watch:
	@echo "Watching for changes..."
	@while true; do \
		find src -name '*.zig' | entr -d -c zig build test; \
	done
