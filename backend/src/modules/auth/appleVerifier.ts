/**
 * Apple Sign In identity-token verification.
 *
 * Apple signs identity tokens with keys published at
 * https://appleid.apple.com/auth/keys (JWKS). We fetch + cache the set, then
 * use `jwtVerify` with `createRemoteJWKSet` to verify the token and extract
 * `sub` (Apple's opaque stable user ID, per-app) and optional `email`.
 */

import { createRemoteJWKSet, jwtVerify } from 'jose';

import { config } from '../../config/index.js';

const APPLE_JWKS_URL = new URL('https://appleid.apple.com/auth/keys');
const APPLE_ISSUER = 'https://appleid.apple.com';

// JOSE's createRemoteJWKSet handles JWKS fetching, caching, and kid-based
// key selection. Default cache duration is 600s; Apple rotates keys rarely.
const appleJwks = createRemoteJWKSet(APPLE_JWKS_URL);

export interface AppleIdentityPayload {
  appleSub: string;
  email?: string;
  emailVerified?: boolean;
}

export async function verifyAppleIdentityToken(
  identityToken: string,
): Promise<AppleIdentityPayload> {
  const { payload } = await jwtVerify(identityToken, appleJwks, {
    issuer: APPLE_ISSUER,
    audience: config.APPLE_BUNDLE_ID,
    clockTolerance: 30,
  });

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Apple identity token missing sub claim');
  }

  return {
    appleSub: payload.sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    emailVerified:
      typeof payload.email_verified === 'boolean'
        ? payload.email_verified
        : payload.email_verified === 'true',
  };
}
