import type {
  Book,
  BookWithClippings,
  Clipping,
  PaginatedResponse,
  PaginationParams,
  SearchAllResponse,
  SearchParams,
} from './types';

function buildQueryString(params: Record<string, string | number | undefined>): string {
  const entries = Object.entries(params).filter(([, v]) => v !== undefined);
  if (entries.length === 0) return '';
  return '?' + entries.map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join('&');
}

async function fetchJson<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${response.statusText}`);
  }
  return response.json();
}

export async function getBooks(params?: PaginationParams): Promise<PaginatedResponse<Book>> {
  const qs = buildQueryString({ limit: params?.limit, offset: params?.offset });
  return fetchJson(`/books${qs}`);
}

export async function getBook(bookId: string, params?: PaginationParams): Promise<BookWithClippings> {
  const qs = buildQueryString({ limit: params?.limit, offset: params?.offset });
  return fetchJson(`/books/${bookId}${qs}`);
}

export async function getClippings(params?: PaginationParams): Promise<PaginatedResponse<Clipping>> {
  const qs = buildQueryString({ limit: params?.limit, offset: params?.offset });
  return fetchJson(`/clippings${qs}`);
}

export async function search(params: SearchParams): Promise<SearchAllResponse | PaginatedResponse<Book> | PaginatedResponse<Clipping>> {
  const qs = buildQueryString({
    q: params.q,
    type: params.type,
    fields: params.fields,
    limit: params.limit,
    offset: params.offset,
  });
  return fetchJson(`/search${qs}`);
}

export async function searchBooks(params: SearchParams): Promise<PaginatedResponse<Book>> {
  return search({ ...params, type: 'books' }) as Promise<PaginatedResponse<Book>>;
}

export async function searchClippings(params: SearchParams): Promise<PaginatedResponse<Clipping>> {
  return search({ ...params, type: 'clippings' }) as Promise<PaginatedResponse<Clipping>>;
}
