export interface Book {
  id: string;
  title: string;
  author: string;
  clipping_count: number;
}

export interface Clipping {
  book_id: string;
  page: number | null;
  location_start: number;
  location_end: number | null;
  added_at: string;
  text: string;
}

export interface PageMeta {
  total: number;
  limit: number;
  offset: number;
  has_more: boolean;
}

export interface PaginatedResponse<T> {
  data: T[];
  meta: PageMeta;
}

export interface BookWithClippings {
  id: string;
  title: string;
  author: string;
  clippings: Clipping[];
  meta: PageMeta;
}

export interface SearchAllResponse {
  clippings: PaginatedResponse<Clipping>;
  books: PaginatedResponse<Book>;
}

export interface PaginationParams {
  limit?: number;
  offset?: number;
}

export interface SearchParams extends PaginationParams {
  q: string;
  type?: 'all' | 'books' | 'clippings';
  fields?: string;
}
