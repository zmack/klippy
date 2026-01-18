.PHONY: build run test clean watch dev frontend-install frontend-build frontend-dev

build: frontend-build
	zig build

run:
	zig build run

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache public/assets public/index.html frontend/node_modules

watch:
	@echo "Watching for changes..."
	@while true; do \
		find src -name '*.zig' | entr -d -c zig build test; \
	done

# Frontend targets
frontend-install:
	cd frontend && npm install

frontend-build: frontend-install
	cd frontend && npm run build

frontend-dev:
	cd frontend && npm run dev

# Run backend and frontend dev servers together
dev:
	@trap 'kill 0' INT; \
	zig build run & \
	cd frontend && npm run dev
