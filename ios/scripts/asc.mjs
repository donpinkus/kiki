#!/usr/bin/env node
// App Store Connect helper for TestFlight releases.
//   node scripts/asc.mjs next-build          -> prints (highest TestFlight build number + 1)
//   node scripts/asc.mjs distribute <build>  -> waits for build to finish processing,
//                                               attaches it to the External group, submits
//                                               it for Beta App Review, prints the public link.
//
// Auth: reads an App Store Connect API key (.p8). The .p8 is the secret and lives OUTSIDE the
// repo (default ~/.appstoreconnect/private_keys/). Key ID / Issuer ID are identifiers, not
// secrets, but can be overridden via env. See documents/references/testflight-release.md.
import { readFileSync } from 'node:fs'
import { sign as cryptoSign } from 'node:crypto'

const CFG = {
  keyId: process.env.ASC_KEY_ID || 'KKBU3VH69S',
  issuerId: process.env.ASC_ISSUER_ID || '227d4525-7a03-4792-8d9e-692a2743778c',
  keyPath: process.env.ASC_KEY_PATH || `${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_KKBU3VH69S.p8`,
  bundleId: process.env.ASC_BUNDLE_ID || 'com.don.Kiki',
  externalGroup: process.env.ASC_EXTERNAL_GROUP || 'External',
}

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

function mintToken() {
  const key = readFileSync(CFG.keyPath)
  const now = Math.floor(Date.now() / 1000)
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: CFG.keyId, typ: 'JWT' }))
  const payload = b64url(JSON.stringify({ iss: CFG.issuerId, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }))
  const signingInput = `${header}.${payload}`
  // ieee-p1363 yields the raw R||S signature JOSE/JWT expects (not DER).
  const sig = cryptoSign('sha256', Buffer.from(signingInput), { key, dsaEncoding: 'ieee-p1363' })
  return `${signingInput}.${b64url(sig)}`
}

const TOKEN = mintToken()
const BASE = 'https://api.appstoreconnect.apple.com'
async function api(path, method = 'GET', body) {
  const r = await fetch(BASE + path, {
    method,
    headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await r.text()
  const json = text ? JSON.parse(text) : null
  return { ok: r.ok, status: r.status, json }
}

async function appId() {
  const r = await api(`/v1/apps?filter[bundleId]=${CFG.bundleId}`)
  const app = r.json?.data?.[0]
  if (!app) throw new Error(`No app for bundleId ${CFG.bundleId}: ${JSON.stringify(r.json)}`)
  return app.id
}

async function cmdNextBuild() {
  const id = await appId()
  const r = await api(`/v1/builds?filter[app]=${id}&sort=-version&limit=20`)
  const nums = (r.json?.data ?? []).map((b) => parseInt(b.attributes.version, 10)).filter((n) => !Number.isNaN(n))
  const highest = nums.length ? Math.max(...nums) : 0
  process.stdout.write(String(highest + 1))
}

async function cmdDistribute(version) {
  if (!version) throw new Error('usage: distribute <buildNumber>')
  const id = await appId()

  // 1. wait for the build to appear and finish processing (VALID)
  let build
  const deadline = Date.now() + 25 * 60 * 1000
  process.stderr.write(`waiting for build ${version} to finish processing`)
  while (Date.now() < deadline) {
    const r = await api(`/v1/builds?filter[app]=${id}&filter[version]=${version}&limit=1`)
    build = r.json?.data?.[0]
    if (build && build.attributes.processingState === 'VALID') break
    process.stderr.write('.')
    await new Promise((res) => setTimeout(res, 20000))
  }
  process.stderr.write('\n')
  if (!build || build.attributes.processingState !== 'VALID') {
    throw new Error(`build ${version} not VALID in time (state=${build?.attributes?.processingState ?? 'absent'})`)
  }

  // 2. find External group
  const groups = await api(`/v1/apps/${id}/betaGroups?limit=200`)
  const ext = groups.json.data.find((g) => g.attributes.name === CFG.externalGroup && !g.attributes.isInternalGroup)
  if (!ext) throw new Error(`External group "${CFG.externalGroup}" not found`)

  // 3. attach build to the group (idempotent — 409 if already attached)
  const attach = await api(`/v1/betaGroups/${ext.id}/relationships/builds`, 'POST', { data: [{ type: 'builds', id: build.id }] })
  console.log(`attach build ${version} -> ${CFG.externalGroup}: ${attach.ok ? 'OK' : attach.status + ' (already attached/err)'}`)

  // 4. submit for Beta App Review (idempotent — Apple auto-approves minor changes)
  const sub = await api('/v1/betaAppReviewSubmissions', 'POST', {
    data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: build.id } } } },
  })
  console.log(`beta review submit: ${sub.ok ? sub.json.data.attributes.betaReviewState : sub.status + ' (already submitted/auto-approved)'}`)

  // 5. report final state + link
  const final = await api(`/v1/builds/${build.id}/betaAppReviewSubmission`)
  console.log(`build ${version} betaReviewState=${final.json?.data?.attributes?.betaReviewState ?? '(none)'}`)
  console.log(`public link: ${ext.attributes.publicLink} (limit ${ext.attributes.publicLinkLimit})`)
}

const [cmd, arg] = process.argv.slice(2)
try {
  if (cmd === 'next-build') await cmdNextBuild()
  else if (cmd === 'distribute') await cmdDistribute(arg)
  else {
    console.error('usage: node scripts/asc.mjs <next-build | distribute <buildNumber>>')
    process.exit(2)
  }
} catch (e) {
  console.error('ERROR:', e.message)
  process.exit(1)
}
