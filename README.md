# Klippy

A REST API for serving Kindle clippings, written in Zig.

## Quick Start

```bash
make run
# Server starts on http://localhost:3000
```

## Endpoints

| Method | Endpoint       | Description                              |
|--------|----------------|------------------------------------------|
| GET    | `/clippings`   | All clippings                            |
| GET    | `/books`       | List of books (id, title, author, count) |
| GET    | `/books/:id`   | Single book with nested clippings        |

## Project Structure

```
src/
├── main.zig              # Entry point, wires library + server
├── server.zig            # HTTP layer, routing, JSON serialization
├── domain.zig            # Public API (re-exports Library, Clipping, Book)
└── domain/
    ├── library.zig       # Domain service - owns data, query methods
    ├── parser.zig        # Parses clippings.txt format
    └── models.zig        # Clipping, Book structs

data/
└── clippings.txt         # Kindle clippings file (My Clippings.txt)
```

## Architecture

- **Parser** reads the Kindle clippings format once at startup
- **Library** holds parsed data in memory, provides query methods
- **Server** handles HTTP, routes requests to Library, serializes JSON
- **No external dependencies** — stdlib only

### Data Flow

```
Startup: clippings.txt → Parser → Library (in-memory)
Request: HTTP → Server → Library → JSON response
```

### Book IDs

Books are identified by a 16-char hex hash of `title + author`. This provides stable, URL-safe IDs.

## Commands

```bash
make build    # Compile
make run      # Build and run server
make test     # Run tests
make clean    # Remove build artifacts
make watch    # Watch mode (requires entr)
```

## Data Format

Expects Kindle's `My Clippings.txt` format:

```
Book Title (Author Name)
- Your Highlight on page X | Location Y-Z | Added on Day, Month DD, YYYY HH:MM:SS AM/PM

Highlighted text here
==========
```

## TODO

- [ ] Authentication
- [ ] Search/filter endpoints
- [ ] Pagination for large responses
- [ ] ISO 8601 date formatting in JSON
