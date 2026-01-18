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
      <h1>Books</h1>

      <form onSubmit={handleSearch} style={{ marginBottom: '1rem' }}>
        <input
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search books..."
          style={{ padding: '0.5rem', width: '300px', marginRight: '0.5rem' }}
        />
        <button type="submit" style={{ padding: '0.5rem 1rem' }}>Search</button>
        {searchQuery && (
          <button
            type="button"
            onClick={() => { setSearchQuery(''); setOffset(0); }}
            style={{ padding: '0.5rem 1rem', marginLeft: '0.5rem' }}
          >
            Clear
          </button>
        )}
      </form>

      {booksQuery.isLoading && <p>Loading...</p>}
      {booksQuery.isError && <p>Error: {booksQuery.error.message}</p>}
      {booksQuery.data && (
        <>
          <p style={{ color: '#666', marginBottom: '1rem' }}>
            Showing {booksQuery.data.data.length} of {booksQuery.data.meta.total} books
          </p>

          <ul style={{ listStyle: 'none', padding: 0 }}>
            {booksQuery.data.data.map((book) => (
              <li key={book.id} style={{ borderBottom: '1px solid #eee', padding: '1rem 0' }}>
                <Link
                  to="/books/$bookId"
                  params={{ bookId: book.id }}
                  style={{ textDecoration: 'none', color: 'inherit' }}
                >
                  <h3 style={{ margin: '0 0 0.25rem 0' }}>{book.title}</h3>
                  <p style={{ margin: 0, color: '#666' }}>
                    by {book.author} &middot; {book.clipping_count} clipping{book.clipping_count !== 1 ? 's' : ''}
                  </p>
                </Link>
              </li>
            ))}
          </ul>

          <div style={{ marginTop: '1rem', display: 'flex', gap: '1rem' }}>
            <button
              onClick={() => setOffset(Math.max(0, offset - limit))}
              disabled={offset === 0}
              style={{ padding: '0.5rem 1rem' }}
            >
              Previous
            </button>
            <button
              onClick={() => setOffset(offset + limit)}
              disabled={!booksQuery.data.meta.has_more}
              style={{ padding: '0.5rem 1rem' }}
            >
              Next
            </button>
          </div>
        </>
      )}
    </div>
  );
}
