import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { listUsers, type UserSummary } from '../api';
import { Spark14 } from '../ActivityBars';

const fmt = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '—');

export function Users() {
  const [q, setQ] = useState('');
  const [users, setUsers] = useState<UserSummary[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const t = setTimeout(() => {
      setLoading(true);
      listUsers(q)
        .then((r) => setUsers(r.users))
        .finally(() => setLoading(false));
    }, 200);
    return () => clearTimeout(t);
  }, [q]);

  return (
    <div className="container">
      <div className="filter-bar">
        <input
          placeholder="Search by email or user id…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          style={{ flex: 1 }}
        />
      </div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>User</th>
              <th>Account</th>
              <th>Created</th>
              <th>Last active</th>
              <th title="In-app minutes per day, last 14 days. Full bar = 15+ min.">Active (14d)</th>
              <th>Sessions</th>
              <th>Drawings</th>
              <th>Events</th>
              <th>Fal $ (mo)</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.user_id}>
                <td>
                  <Link to={`/users/${u.user_id}`}>{u.email || <span className="mono">{u.user_id}</span>}</Link>
                  {u.email && <div className="mono muted">{u.user_id}</div>}
                </td>
                <td>
                  {u.is_test_account
                    ? 'test'
                    : u.subscription_status === 'active'
                      ? 'subscriber'
                      : <span className="muted">user</span>}
                </td>
                <td className="muted">{fmt(u.created_at)}</td>
                <td className="muted">{fmt(u.last_seen)}</td>
                <td>
                  <Spark14 data={u.activity14d ?? []} />
                </td>
                <td>{u.session_count}</td>
                <td>{u.drawing_count}</td>
                <td>{u.event_count}</td>
                <td>${u.fal_spend_usd_month.toFixed(2)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {!loading && users.length === 0 && (
          <div className="muted" style={{ padding: 20 }}>No users yet.</div>
        )}
      </div>
    </div>
  );
}
