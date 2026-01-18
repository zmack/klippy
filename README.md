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
src/
├── main.zig              # Entry point, wires library + server
├── server.zig            # HTTP layer, routing, JSON serialization
├── domain.zig            # Public API (re-exports Library, Clipping, Book)
└── domain/
    ├── library.zig       # Domain service - owns data, query methods, search
    ├── parser.zig        # Parses clippings.txt format
    └── models.zig        # Clipping, Book structs

data/
└── clippings.txt         # Kindle clippings file (My Clippings.txt)

public/                   # Static files served by the server
├── index.html            # Main entry point (served at /)
├── assets/               # CSS, JS, images (served at /assets/*)
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

- [x] Search endpoint with field filtering
- [x] Static file serving
- [x] Index page route
- [ ] Frontend UI
- [ ] Authentication

## Frontend Development

The backend is ready to serve a frontend. To implement the UI:

1. Create `public/index.html` as the main entry point
2. Place CSS/JS in `public/` (served via `/assets/*`)

**Available API endpoints for the frontend:**

| Endpoint | Use Case |
|----------|----------|
| `GET /books` | List all books with clipping counts |
| `GET /books/:id` | Get book details + clippings |
| `GET /clippings` | Browse all clippings |
| `GET /search?q=...` | Search across books and clippings |

**Suggested features:**
- Book list view with search
- Book detail view showing clippings
- Global search with type filtering
- Pagination controls

**Example fetch:**
```javascript
const response = await fetch('/search?q=philosophy&type=books');
const { data, meta } = await response.json();
```
