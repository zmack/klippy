import { createFileRoute, Link, useNavigate } from '@tanstack/react-router';
import { useQuery } from '@tanstack/react-query';
import { getBook } from '../api/client';
import { useState, useEffect, useRef } from 'react';
import { Flashcard } from '../components/Flashcard';

export const Route = createFileRoute('/books/$bookId')({
  component: BookPage,
});

type ViewMode = 'list' | 'flashcard';

function BookPage() {
  const { bookId } = Route.useParams();
  const [offset, setOffset] = useState(0);
  const [viewMode, setViewMode] = useState<ViewMode>('flashcard');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const navigate = useNavigate();
  const listRef = useRef<HTMLUListElement>(null);
  const limit = 100;

  const bookQuery = useQuery({
    queryKey: ['book', bookId, offset],
    queryFn: () => getBook(bookId, { limit, offset }),
  });

  const clippings = bookQuery.data?.clippings ?? [];

  // Scroll selected item into view
  useEffect(() => {
    if (viewMode === 'list' && listRef.current) {
      const item = listRef.current.children[selectedIndex] as HTMLElement;
      item?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }, [selectedIndex, viewMode]);

  useEffect(() => {
    if (viewMode !== 'list') return;

    const handleKeyDown = (e: KeyboardEvent) => {
      switch (e.key) {
        case 'j':
        case 'ArrowDown':
          e.preventDefault();
          setSelectedIndex(i => Math.min(i + 1, clippings.length - 1));
          break;
        case 'k':
        case 'ArrowUp':
          e.preventDefault();
          setSelectedIndex(i => Math.max(i - 1, 0));
          break;
        case 'f':
          e.preventDefault();
          setViewMode('flashcard');
          break;
        case 'q':
          e.preventDefault();
          navigate({ to: '/' });
          break;
        case 'g':
          setSelectedIndex(0);
          break;
        case 'G':
          setSelectedIndex(clippings.length - 1);
          break;
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [viewMode, clippings.length, navigate]);

  const formatDate = (dateStr: string) => {
    const date = new Date(dateStr);
    return date.toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
    });
  };

  if (viewMode === 'flashcard' && bookQuery.data && bookQuery.data.clippings.length > 0) {
    return (
      <div>
        <h1 className="page-title">{bookQuery.data.title}</h1>
        <p className="page-subtitle">by {bookQuery.data.author}</p>
        <Flashcard
          clippings={bookQuery.data.clippings}
          onExit={() => setViewMode('list')}
        />
      </div>
    );
  }

  return (
    <div>
      <Link to="/" className="back-link">
        ← Back to library
      </Link>

      {bookQuery.isLoading && <p className="loading">Loading book...</p>}
      {bookQuery.isError && <p className="error">Error: {bookQuery.error.message}</p>}
      {bookQuery.data && (
        <>
          <h1 className="page-title">{bookQuery.data.title}</h1>
          <p className="page-subtitle">by {bookQuery.data.author}</p>

          <h2 className="section-title">Clippings</h2>

          {bookQuery.data.clippings.length > 0 && (
            <div className="view-toggle">
              <button
                className={`btn btn-secondary ${viewMode === 'list' ? 'active' : ''}`}
                onClick={() => setViewMode('list')}
              >
                📋 List
              </button>
              <button
                className={`btn btn-secondary ${viewMode === 'flashcard' ? 'active' : ''}`}
                onClick={() => setViewMode('flashcard')}
              >
                🎴 Flashcards
              </button>
            </div>
          )}

          <p className="results-summary">
            {bookQuery.data.meta.total} clipping{bookQuery.data.meta.total !== 1 ? 's' : ''}
            <span className="kbd-hint"> · J/K navigate · F flashcards · Q back</span>
          </p>

          {bookQuery.data.clippings.length === 0 ? (
            <div className="empty-state">
              <div className="empty-state-icon">✂️</div>
              <p>No clippings for this book yet</p>
            </div>
          ) : (
            <ul className="clipping-list" ref={listRef}>
              {bookQuery.data.clippings.map((clipping, idx) => (
                <li
                  key={idx}
                  className={`clipping-card ${idx === selectedIndex ? 'is-focused' : ''}`}
                >
                  <p className="clipping-text">{clipping.text}</p>
                  <div className="clipping-meta">
                    {clipping.page && (
                      <>
                        <span>📄 Page {clipping.page}</span>
                        <span className="meta-divider">·</span>
                      </>
                    )}
                    <span>
                      📍 Location {clipping.location_start}
                      {clipping.location_end && `–${clipping.location_end}`}
                    </span>
                    <span className="meta-divider">·</span>
                    <span>📅 {formatDate(clipping.added_at)}</span>
                  </div>
                </li>
              ))}
            </ul>
          )}

          {bookQuery.data.meta.has_more && (
            <div className="pagination">
              <button
                onClick={() => setOffset(offset + limit)}
                className="btn btn-secondary"
              >
                Load more
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
