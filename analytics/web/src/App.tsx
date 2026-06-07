import { useEffect, useState } from 'react';
import { Navigate, Route, Routes, useNavigate } from 'react-router-dom';
import { checkAuth, isAuthError, logout } from './api';
import { Login } from './pages/Login';
import { Users } from './pages/Users';
import { UserDetail } from './pages/UserDetail';

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
        <button className="ghost" onClick={onLogout}>
          Sign out
        </button>
      </div>
      <Routes>
        <Route path="/" element={<Users />} />
        <Route path="/users/:id" element={<UserDetail />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </>
  );
}
