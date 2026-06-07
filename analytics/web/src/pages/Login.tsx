import { useState } from 'react';
import { login } from '../api';

export function Login({ onAuthed }: { onAuthed: () => void }) {
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      await login(password);
      onAuthed();
    } catch {
      setError('Invalid password');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="center">
      <form className="card" style={{ width: 320 }} onSubmit={submit}>
        <h1 style={{ marginTop: 0, fontSize: 18 }}>Kiki Insights</h1>
        <p className="muted" style={{ marginTop: 0 }}>Internal — sign in to continue.</p>
        <input
          type="password"
          placeholder="Admin password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          style={{ width: '100%', marginBottom: 12 }}
          autoFocus
        />
        {error && <div className="error" style={{ marginBottom: 12 }}>{error}</div>}
        <button type="submit" disabled={busy} style={{ width: '100%' }}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </div>
  );
}
