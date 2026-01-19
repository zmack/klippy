import { useState, useEffect, useCallback } from 'react';
import type { Clipping } from '../api/types';

interface FlashcardProps {
  clippings: Clipping[];
  onExit: () => void;
}

export function Flashcard({ clippings, onExit }: FlashcardProps) {
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isFlipped, setIsFlipped] = useState(false);
  const [direction, setDirection] = useState<'next' | 'prev' | null>(null);

  const currentClipping = clippings[currentIndex];
  const progress = ((currentIndex + 1) / clippings.length) * 100;

  const goNext = useCallback(() => {
    if (currentIndex < clippings.length - 1) {
      setDirection('next');
      setIsFlipped(false);
      setTimeout(() => {
        setCurrentIndex(i => i + 1);
        setDirection(null);
      }, 150);
    }
  }, [currentIndex, clippings.length]);

  const goPrev = useCallback(() => {
    if (currentIndex > 0) {
      setDirection('prev');
      setIsFlipped(false);
      setTimeout(() => {
        setCurrentIndex(i => i - 1);
        setDirection(null);
      }, 150);
    }
  }, [currentIndex]);

  const flip = useCallback(() => {
    setIsFlipped(f => !f);
  }, []);

  const goToRandom = useCallback(() => {
    const randomIndex = Math.floor(Math.random() * clippings.length);
    setDirection(randomIndex > currentIndex ? 'next' : 'prev');
    setIsFlipped(false);
    setTimeout(() => {
      setCurrentIndex(randomIndex);
      setDirection(null);
    }, 150);
  }, [clippings.length, currentIndex]);

  const goToFirst = useCallback(() => {
    if (currentIndex !== 0) {
      setDirection('prev');
      setIsFlipped(false);
      setTimeout(() => {
        setCurrentIndex(0);
        setDirection(null);
      }, 150);
    }
  }, [currentIndex]);

  const goToLast = useCallback(() => {
    const lastIndex = clippings.length - 1;
    if (currentIndex !== lastIndex) {
      setDirection('next');
      setIsFlipped(false);
      setTimeout(() => {
        setCurrentIndex(lastIndex);
        setDirection(null);
      }, 150);
    }
  }, [clippings.length, currentIndex]);

  const goToPercent = useCallback((percent: number) => {
    const targetIndex = Math.floor((percent / 100) * (clippings.length - 1));
    if (targetIndex !== currentIndex) {
      setDirection(targetIndex > currentIndex ? 'next' : 'prev');
      setIsFlipped(false);
      setTimeout(() => {
        setCurrentIndex(targetIndex);
        setDirection(null);
      }, 150);
    }
  }, [clippings.length, currentIndex]);

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      switch (e.key) {
        case 'ArrowRight':
        case 'j':
          goNext();
          break;
        case 'ArrowLeft':
        case 'k':
          goPrev();
          break;
        case ' ':
        case 'Enter':
          e.preventDefault();
          flip();
          break;
        case 'q':
          onExit();
          break;
        case 'r':
          goToRandom();
          break;
        case 'Home':
        case 'g':
          goToFirst();
          break;
        case 'End':
        case 'G':
          goToLast();
          break;
        case '1':
          goToPercent(10);
          break;
        case '2':
          goToPercent(20);
          break;
        case '3':
          goToPercent(30);
          break;
        case '4':
          goToPercent(40);
          break;
        case '5':
          goToPercent(50);
          break;
        case '6':
          goToPercent(60);
          break;
        case '7':
          goToPercent(70);
          break;
        case '8':
          goToPercent(80);
          break;
        case '9':
          goToPercent(90);
          break;
        case '0':
          goToFirst();
          break;
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [goNext, goPrev, flip, onExit, goToRandom, goToFirst, goToLast, goToPercent]);

  const formatDate = (dateStr: string) => {
    return new Date(dateStr).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
    });
  };

  const getTextSizeClass = (text: string) => {
    const len = text.length;
    if (len > 500) return 'text-long';
    if (len > 250) return 'text-medium';
    return '';
  };

  return (
    <div className="flashcard-container">
      <div className="flashcard-header">
        <button onClick={onExit} className="btn btn-secondary">
          ← Back to list
        </button>
        <div className="flashcard-counter">
          {currentIndex + 1} / {clippings.length}
        </div>
      </div>

      <div className="flashcard-progress">
        <div className="flashcard-progress-bar" style={{ width: `${progress}%` }} />
      </div>

      <div className="flashcard-stage">
        <button
          className="flashcard-nav flashcard-nav-prev"
          onClick={goPrev}
          disabled={currentIndex === 0}
          aria-label="Previous"
        >
          ‹
        </button>

        <div
          className={`flashcard ${isFlipped ? 'is-flipped' : ''} ${direction ? `slide-${direction}` : ''}`}
          onClick={flip}
        >
          <div className="flashcard-inner">
            <div className="flashcard-front">
              <div className="flashcard-content">
                <p className={`flashcard-text ${getTextSizeClass(currentClipping.text)}`}>{currentClipping.text}</p>
              </div>
              <div className="flashcard-hint">Click or press Space to flip</div>
            </div>
            <div className="flashcard-back">
              <div className="flashcard-content">
                <div className="flashcard-meta-grid">
                  {currentClipping.page && (
                    <div className="flashcard-meta-item">
                      <span className="flashcard-meta-label">Page</span>
                      <span className="flashcard-meta-value">{currentClipping.page}</span>
                    </div>
                  )}
                  <div className="flashcard-meta-item">
                    <span className="flashcard-meta-label">Location</span>
                    <span className="flashcard-meta-value">
                      {currentClipping.location_start}
                      {currentClipping.location_end && `–${currentClipping.location_end}`}
                    </span>
                  </div>
                  <div className="flashcard-meta-item">
                    <span className="flashcard-meta-label">Added</span>
                    <span className="flashcard-meta-value">{formatDate(currentClipping.added_at)}</span>
                  </div>
                </div>
              </div>
              <div className="flashcard-hint">Click or press Space to flip back</div>
            </div>
          </div>
        </div>

        <button
          className="flashcard-nav flashcard-nav-next"
          onClick={goNext}
          disabled={currentIndex === clippings.length - 1}
          aria-label="Next"
        >
          ›
        </button>
      </div>

      <div className="flashcard-instructions">
        <span>J/K navigate</span>
        <span>Space flip</span>
        <span>R random</span>
        <span>0-9 jump</span>
        <span>Q exit</span>
      </div>
    </div>
  );
}
