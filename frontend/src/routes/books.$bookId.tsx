import { createFileRoute, Link } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { getBook } from '../api/client';
import { useState } from 'react';

export const Route = createFileRoute('/books/$bookId')({
  component: BookPage,
});

function BookPage() {
  const { bookId } = Route.useParams();
  const [offset, setOffset] = useState(0);
  const limit = 20;

  const bookQuery = useQuery({
    queryKey: ['book', bookId, offset],
    queryFn: () => getBook(bookId, { limit, offset }),
  });

  return (
    <div>
      <Link to="/" style={{ color: '#666', textDecoration: 'none' }}>
        &larr; Back to books
      </Link>

      {bookQuery.isLoading && <p>Loading...</p>}
      {bookQuery.isError && <p>Error: {bookQuery.error.message}</p>}
      {bookQuery.data && (
        <>
          <h1 style={{ marginTop: '1rem' }}>{bookQuery.data.title}</h1>
          <p style={{ color: '#666' }}>by {bookQuery.data.author}</p>

          <h2 style={{ marginTop: '2rem' }}>Clippings</h2>
          <p style={{ color: '#666', marginBottom: '1rem' }}>
            Showing {bookQuery.data.clippings.length} of {bookQuery.data.meta.total} clippings
          </p>

          {bookQuery.data.clippings.length === 0 ? (
            <p>No clippings for this book.</p>
          ) : (
            <ul style={{ listStyle: 'none', padding: 0 }}>
              {bookQuery.data.clippings.map((clipping, idx) => (
                <li key={idx} style={{ borderBottom: '1px solid #eee', padding: '1rem 0' }}>
                  <blockquote style={{ margin: 0, fontStyle: 'italic', lineHeight: '1.6' }}>
                    "{clipping.text}"
                  </blockquote>
                  <p style={{ margin: '0.5rem 0 0 0', color: '#999', fontSize: '0.875rem' }}>
                    {clipping.page && `Page ${clipping.page} · `}
                    Location {clipping.location_start}
                    {clipping.location_end && `-${clipping.location_end}`}
                    {' · '}
                    {new Date(clipping.added_at).toLocaleDateString()}
                  </p>
                </li>
              ))}
            </ul>
          )}

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
              disabled={!bookQuery.data.meta.has_more}
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
