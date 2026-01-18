import { createRootRoute, Link, Outlet } from '@tanstack/react-router';
import { TanStackRouterDevtools } from '@tanstack/router-devtools';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <div className="app-container">
      <header className="header">
        <Link to="/" className="logo">
          <span className="logo-icon">📚</span>
          Klippy
        </Link>
      </header>
      <main className="main-content">
        <Outlet />
      </main>
      <TanStackRouterDevtools />
    </div>
  );
}
