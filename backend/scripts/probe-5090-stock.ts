/* Throwaway: probe RTX 5090 on-demand stock across all RunPod DCs. */
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { getGpuStock, listDataCenters } from './lib/runpod-graphql';

const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const OUR_IMAGE_DCS = new Set(['EU-CZ-1', 'EU-RO-1', 'US-IL-1', 'US-NC-1']);

// load RUNPOD_API_KEY from repo-root .env.local
const envPath = '/Users/donald/Desktop/kiki_root/.env.local';
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf-8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m && m[1] && !process.env[m[1]]) {
      let v = m[2] ?? '';
      if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith('"') && v.endsWith('"'))) v = v.slice(1, -1);
      process.env[m[1]] = v;
    }
  }
}

const rank = (s: string | null) => ({ High: 4, Medium: 3, Low: 2, None: 1 } as Record<string, number>)[s ?? ''] ?? 0;

async function main() {
  const dcs = await listDataCenters();
  const rows = await Promise.all(
    dcs.map(async (dc) => {
      try {
        const stock = await getGpuStock(GPU_TYPE_ID, dc);
        return { dc, ...stock, err: null as string | null };
      } catch (e) {
        return { dc, stockStatus: null, uninterruptablePrice: null, err: (e as Error).message };
      }
    }),
  );
  rows.sort((a, b) => rank(b.stockStatus) - rank(a.stockStatus) || a.dc.localeCompare(b.dc));
  console.log(`\nRTX 5090 on-demand stock — ${rows.length} DCs  (★ = we hold image volumes)\n`);
  console.log('  DC          stock    $/hr     ours');
  console.log('  ─────────────────────────────────────');
  for (const r of rows) {
    const star = OUR_IMAGE_DCS.has(r.dc) ? '★' : ' ';
    const price = r.uninterruptablePrice != null ? `$${r.uninterruptablePrice.toFixed(2)}` : '—';
    const status = r.err ? `ERR` : (r.stockStatus ?? 'null');
    console.log(`  ${r.dc.padEnd(10)} ${status.padEnd(8)} ${price.padEnd(8)} ${star}`);
  }
  const available = rows.filter((r) => r.stockStatus && r.stockStatus !== 'None');
  const oursAvail = available.filter((r) => OUR_IMAGE_DCS.has(r.dc));
  console.log(`\n  ${available.length}/${rows.length} DCs have stock; ${oursAvail.length}/4 of OUR image DCs have stock.`);
}
main().catch((e) => { console.error(e); process.exit(1); });
