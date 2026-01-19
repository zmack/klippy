# Klippy

A keyboard-driven app for browsing and reviewing Kindle clippings. Zig backend, React frontend.

## Quick Start

```bash
make run
# Server starts on http://localhost:3000
```

## Endpoints

| Method | Endpoint       | Description                              |
|--------|----------------|------------------------------------------|
| GET    | `/`            | Serves `public/index.html`               |
| GET    | `/clippings`   | All clippings (paginated)                |
| GET    | `/books`       | List of books (paginated)                |
| GET    | `/books/:id`   | Single book with clippings (paginated)   |
| GET    | `/search`      | Search books and clippings               |
| GET    | `/assets/*`    | Static files from `public/` directory    |

### Pagination

All endpoints support pagination via query params:

```
?limit=20&offset=0
```

- `limit`: max items per page (default: 20, max: 100)
- `offset`: number of items to skip

### Response Format

```json
{
  "data": [...],
  "meta": {
    "total": 722,
    "limit": 20,
    "offset": 0,
    "has_more": true
  }
}
```

### Ordering

- **Books**: by most recent clipping date (desc), then by ID
- **Clippings**: by date added (desc, newest first)

### Search

```
GET /search?q=<query>&type=<type>&fields=<fields>
```

**Parameters:**
- `q` (required): Search query (case-insensitive substring match)
- `type`: `all` (default), `books`, or `clippings`
- `fields`: Comma-separated list of `title`, `author`, `text` (default: all)
- `limit`, `offset`: Pagination (same as other endpoints)

**Examples:**
```bash
# Search everything
curl "http://localhost:3000/search?q=philosophy"

# Search only books by title
curl "http://localhost:3000/search?q=war&type=books&fields=title"

# Search clippings text
curl "http://localhost:3000/search?q=happiness&type=clippings&fields=text"
```

**Response format for `type=all`:**
```json
{
  "clippings": { "data": [...], "meta": {...} },
  "books": { "data": [...], "meta": {...} }
}
```

### Static Files

Files in `public/` are served via `/assets/*`:
- `public/style.css` → `GET /assets/style.css`
- `public/app.js` → `GET /assets/app.js`

The root path `/` (and `/index.html`, `/index.htm`) serves `public/index.html`.

**Supported MIME types:** HTML, CSS, JS, JSON, PNG, JPEG, GIF, SVG, ICO, WOFF, WOFF2, TXT

## Project Structure

```
src/                      # Zig backend
├── main.zig              # Entry point, wires library + server
├── server.zig            # HTTP layer, routing, JSON serialization
├── domain.zig            # Public API (re-exports Library, Clipping, Book)
└── domain/
    ├── library.zig       # Domain service - owns data, query methods, search
    ├── parser.zig        # Parses clippings.txt format
    └── models.zig        # Clipping, Book structs

frontend/                 # React frontend (Vite)
├── src/
│   ├── main.tsx          # Entry point
│   ├── App.tsx           # Router + Query providers
│   ├── routes/           # TanStack Router pages
│   ├── api/              # API client + types
│   └── components/       # Shared components
├── index.html
├── vite.config.ts
└── package.json

data/
└── clippings.txt         # Kindle clippings file (My Clippings.txt)

public/                   # Built frontend (generated, served by Zig)
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
make build    # Build frontend + backend
make run      # Run server (serves built frontend)
make dev      # Run frontend + backend dev servers
make test     # Run Zig tests
make clean    # Remove all build artifacts
make watch    # Watch mode for Zig (requires entr)
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

- [x] Search endpoint with field filtering
- [x] Static file serving
- [x] Index page route
- [x] Frontend UI
- [ ] Authentication

## Frontend

A React SPA built with Vite, TanStack Router, and TanStack Query.

### Running

```bash
# Development (frontend + backend)
make dev

# Production build
make build
make run
# Visit http://localhost:3000
```

### Features

- **Book library** — Browse all books with clipping counts
- **Search** — Filter books by title/author
- **Flashcard mode** — Review clippings one at a time with flip animation
- **Keyboard-driven** — Full vim-style navigation

### Keyboard Shortcuts

**Book list:**
| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up/down |
| `o` / `Enter` | Open book |
| `/` | Focus search |
| `g` / `G` | First / last |

**Clipping list:**
| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up/down |
| `f` | Switch to flashcards |
| `q` | Back to library |
| `g` / `G` | First / last |

**Flashcard mode:**
| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous card |
| `Space` | Flip card |
| `r` | Random card |
| `0-9` | Jump to 0-90% |
| `g` / `G` | First / last |
| `q` | Exit to list |

### Tech Stack

- **Vite** — Build tool with HMR
- **React 19** — UI framework
- **TanStack Router** — File-based routing
- **TanStack Query** — Data fetching and caching
- **TypeScript** — Type safety
