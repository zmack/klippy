import { createFileRoute, Link, useNavigate } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { getBooks, searchBooks } from '../api/client';
import { useState, useEffect, useCallback, useRef } from 'react';
import type { PaginatedResponse, Book } from '../api/types';

export const Route = createFileRoute('/')({
  component: HomePage,
});

function HomePage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [offset, setOffset] = useState(0);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const searchInputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const navigate = useNavigate();
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

  const books = booksQuery.data?.data ?? [];

  // Reset selection when data changes
  useEffect(() => {
    setSelectedIndex(0);
  }, [offset, searchQuery]);

  // Scroll selected item into view
  useEffect(() => {
    if (listRef.current && books.length > 0) {
      const item = listRef.current.children[selectedIndex] as HTMLElement;
      item?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }, [selectedIndex, books.length]);

  const openSelected = useCallback(() => {
    if (books[selectedIndex]) {
      navigate({ to: '/books/$bookId', params: { bookId: books[selectedIndex].id } });
    }
  }, [books, selectedIndex, navigate]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Don't handle if typing in search
      if (document.activeElement === searchInputRef.current) {
        if (e.key === 'Escape') {
          searchInputRef.current?.blur();
        }
        return;
      }

      switch (e.key) {
        case 'j':
        case 'ArrowDown':
          e.preventDefault();
          setSelectedIndex(i => Math.min(i + 1, books.length - 1));
          break;
        case 'k':
        case 'ArrowUp':
          e.preventDefault();
          setSelectedIndex(i => Math.max(i - 1, 0));
          break;
        case 'o':
        case 'Enter':
          e.preventDefault();
          openSelected();
          break;
        case '/':
          e.preventDefault();
          searchInputRef.current?.focus();
          break;
        case 'g':
          setSelectedIndex(0);
          break;
        case 'G':
          setSelectedIndex(books.length - 1);
          break;
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [books.length, openSelected]);

  const handleSearch = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setOffset(0);
    searchInputRef.current?.blur();
  };

  return (
    <div>
      <h1 className="page-title">Your Library</h1>
      <p className="page-subtitle">Highlights and notes from your reading</p>

      <form onSubmit={handleSearch} className="search-form">
        <input
          ref={searchInputRef}
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search your books... (press /)"
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
            Showing {books.length} of {booksQuery.data.meta.total} books
            <span className="kbd-hint"> · J/K navigate · O open · / search</span>
          </p>

          {books.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">📖</div>
              <p>No books found</p>
            </div>
          ) : (
            <ul className="book-list" ref={listRef}>
              {books.map((book, index) => (
                <li
                  key={book.id}
                  className={`book-card ${index === selectedIndex ? 'is-focused' : ''}`}
                >
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
