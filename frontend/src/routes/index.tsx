import { createFileRoute, Link } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { getBooks, searchBooks } from '../api/client';
import { useState } from 'react';
import type { PaginatedResponse, Book } from '../api/types';

export const Route = createFileRoute('/')({
  component: HomePage,
});

function HomePage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [offset, setOffset] = useState(0);
  const limit = 20;

  const booksQuery = useQuery({
    queryKey: ['books', offset, searchQuery],
    queryFn: async (): Promise<PaginatedResponse<Book>> => {
      if (searchQuery.trim()) {
        return searchBooks({ q: searchQuery, limit, offset });
      }
      return getBooks({ limit, offset });
    },
  });

  const handleSearch = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setOffset(0);
  };

  return (
    <div>
      <h1 className="page-title">Your Library</h1>
      <p className="page-subtitle">Highlights and notes from your reading</p>

      <form onSubmit={handleSearch} className="search-form">
        <input
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search your books..."
          className="search-input"
        />
        <button type="submit" className="btn btn-primary">Search</button>
        {searchQuery && (
          <button
            type="button"
            onClick={() => { setSearchQuery(''); setOffset(0); }}
            className="btn btn-secondary"
          >
            Clear
          </button>
        )}
      </form>

      {booksQuery.isLoading && <p className="loading">Gathering your books...</p>}
      {booksQuery.isError && <p className="error">Error: {booksQuery.error.message}</p>}
      {booksQuery.data && (
        <>
          <p className="results-summary">
            Showing {booksQuery.data.data.length} of {booksQuery.data.meta.total} books
          </p>

          {booksQuery.data.data.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">📖</div>
              <p>No books found</p>
            </div>
          ) : (
            <ul className="book-list">
              {booksQuery.data.data.map((book) => (
                <li key={book.id} className="book-card">
                  <Link
                    to="/books/$bookId"
                    params={{ bookId: book.id }}
                    className="book-card-link"
                  >
                    <h3 className="book-title">{book.title}</h3>
                    <p className="book-author">by {book.author}</p>
                    <div className="book-meta">
                      <span className="clipping-count">
                        ✂️ {book.clipping_count} clipping{book.clipping_count !== 1 ? 's' : ''}
                      </span>
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}

          <div className="pagination">
            <button
              onClick={() => setOffset(Math.max(0, offset - limit))}
              disabled={offset === 0}
              className="btn btn-secondary"
            >
              ← Previous
            </button>
            <button
              onClick={() => setOffset(offset + limit)}
              disabled={!booksQuery.data.meta.has_more}
              className="btn btn-secondary"
            >
              Next →
            </button>
          </div>
        </>
      )}
    </div>
  );
}
