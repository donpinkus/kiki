import { useEffect, useState } from 'react';
import { Link, Navigate, Route, Routes, useNavigate } from 'react-router-dom';
import { checkAuth, isAuthError, logout } from './api';
import { Login } from './pages/Login';
import { Users } from './pages/Users';
import { UserDetail } from './pages/UserDetail';
import { Ops } from './pages/Ops';
import { Gallery } from './pages/Gallery';
import { Replay } from './pages/Replay';
import { Tests } from './pages/Tests';
import { Launch } from './pages/Launch';

type AuthState = 'loading' | 'authed' | 'anon';

export function App() {
  const [auth, setAuth] = useState<AuthState>('loading');
  const navigate = useNavigate();

  useEffect(() => {
    checkAuth()
      .then(() => setAuth('authed'))
      .catch((e) => setAuth(isAuthError(e) ? 'anon' : 'anon'));
  }, []);

  if (auth === 'loading') return <div className="center muted">Loading…</div>;

  if (auth === 'anon') {
    return (
      <Routes>
        <Route path="*" element={<Login onAuthed={() => setAuth('authed')} />} />
      </Routes>
    );
  }

  const onLogout = async () => {
    await logout();
    setAuth('anon');
    navigate('/');
  };

  return (
    <>
      <div className="topbar">
        <h1>Kiki Insights</h1>
        <nav style={{ display: 'flex', gap: 16, flex: 1, marginLeft: 24 }}>
          <Link to="/launch">Launch</Link>
          <Link to="/">Users</Link>
          <Link to="/gallery">Gallery</Link>
          <Link to="/tests">Tests</Link>
          <Link to="/ops">Ops</Link>
        </nav>
        <button className="ghost" onClick={onLogout}>
          Sign out
        </button>
      </div>
      <Routes>
        <Route path="/" element={<Users />} />
        <Route path="/launch" element={<Launch />} />
        <Route path="/users/:id" element={<UserDetail />} />
        <Route path="/gallery" element={<Gallery />} />
        <Route path="/gallery/:streamId" element={<Replay />} />
        <Route path="/tests" element={<Tests />} />
        <Route path="/ops" element={<Ops />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </>
  );
}
