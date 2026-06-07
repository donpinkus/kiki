/**
 * Apple StoreKit transaction + App Store Server Notification (V2) JWS
 * verification, wrapping Apple's official `@apple/app-store-server-library`.
 *
 * We VERIFY signed payloads (we never call Apple's REST App Store Server API),
 * so no `.p8` key is needed — only the Apple Root CA trust anchor. The library's
 * `SignedDataVerifier` does the full x5c cert-chain validation we must not
 * hand-roll for a payment trust boundary.
 *
 * Environment routing: the library pins each verifier to ONE `Environment` and
 * rejects a payload whose environment differs (INVALID_ENVIRONMENT). A
 * production build legitimately receives Sandbox transactions (TestFlight / App
 * Review), so we keep a verifier per environment and route by peeking the
 * (still-unverified) payload's `environment` field — the subsequent verify is
 * what authenticates, so peeking is safe.
 */

import { Buffer } from 'node:buffer';

import {
  Environment,
  SignedDataVerifier,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from '@apple/app-store-server-library';

import { config } from '../../config/index.js';

/** The one auto-renewable subscription product. Must match App Store Connect. */
export const KIKI_SUBSCRIPTION_PRODUCT_ID = 'com.don.Kiki.pro.monthly';

// Apple Root CA - G3 (DER, base64). Public trust anchor for the x5c chain on
// every StoreKit transaction + App Store Server Notification JWS. Source:
// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer — also committed
// at ./certs/AppleRootCA-G3.cer for audit. Embedded (rather than read from disk)
// so it survives `tsc` without a build-copy step and behaves identically under
// tsx (dev) and node dist (prod). Regenerate: `base64 -i certs/AppleRootCA-G3.cer`.
const APPLE_ROOT_CA_G3_B64 =
  'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==';

const appleRootCerts: Buffer[] = [Buffer.from(APPLE_ROOT_CA_G3_B64, 'base64')];

// `enableOnlineChecks=false`: revocation arrives via REFUND/REVOKE
// notifications, so we skip the per-verify OCSP network round-trip (keeps the
// hot per-launch entitlement re-post fast).
function makeVerifier(env: Environment, appAppleId?: number): SignedDataVerifier {
  return new SignedDataVerifier(appleRootCerts, false, env, config.APPLE_BUNDLE_ID, appAppleId);
}

// Sandbox covers TestFlight + sandbox testers and needs no app id.
const sandboxVerifier = makeVerifier(Environment.SANDBOX);

// Production verifier requires the numeric App Store app id (the library throws
// without it). Built only once APPLE_APP_APPLE_ID is configured; until then,
// production payloads are rejected with a clear error — sandbox/TestFlight is
// unaffected, so this doesn't block pre-launch testing.
const productionVerifier =
  config.APPLE_APP_APPLE_ID > 0 ? makeVerifier(Environment.PRODUCTION, config.APPLE_APP_APPLE_ID) : null;

// XCODE / LOCAL_TESTING payloads are NOT App-Store-signed — the library skips
// signature verification for them. That's a trust bypass, so we only enable
// these outside production. The payoff: a local `.storekit` simulator purchase
// can exercise the full backend path in dev.
const allowLocalEnvs = config.NODE_ENV !== 'production';
const xcodeVerifier = allowLocalEnvs ? makeVerifier(Environment.XCODE) : null;
const localTestingVerifier = allowLocalEnvs ? makeVerifier(Environment.LOCAL_TESTING) : null;

function verifierFor(env: string | undefined): SignedDataVerifier {
  switch (env) {
    case Environment.SANDBOX:
      return sandboxVerifier;
    case Environment.PRODUCTION:
      if (!productionVerifier) {
        throw new Error('Production StoreKit verifier unavailable — set APPLE_APP_APPLE_ID');
      }
      return productionVerifier;
    case Environment.XCODE:
      if (!xcodeVerifier) throw new Error('Xcode-environment payloads are rejected in production');
      return xcodeVerifier;
    case Environment.LOCAL_TESTING:
      if (!localTestingVerifier) throw new Error('LocalTesting payloads are rejected in production');
      return localTestingVerifier;
    default:
      throw new Error(`Unknown StoreKit environment: ${String(env)}`);
  }
}

/**
 * Decode (WITHOUT verifying) a JWS body to read the one field we need to pick
 * the right environment verifier. Safe: the subsequent verify authenticates;
 * an attacker spoofing `environment` just routes to a verifier that rejects them.
 */
function decodeJwsBody(jws: string): Record<string, unknown> {
  const seg = jws.split('.')[1];
  if (!seg) throw new Error('Malformed JWS (no payload segment)');
  return JSON.parse(Buffer.from(seg, 'base64url').toString('utf8')) as Record<string, unknown>;
}

/** Verify + decode a StoreKit `Transaction.jwsRepresentation`. Throws on any
 * chain/signature/bundle/environment failure. */
export async function verifyTransaction(jws: string): Promise<JWSTransactionDecodedPayload> {
  const env = decodeJwsBody(jws)['environment'] as string | undefined;
  return verifierFor(env).verifyAndDecodeTransaction(jws);
}

/** Verify + decode an App Store Server Notification V2 `signedPayload`. The JWS
 * signature is the authentication for this otherwise-unauthenticated webhook. */
export async function verifyNotification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload> {
  const body = decodeJwsBody(signedPayload);
  const data = body['data'] as { environment?: string } | undefined;
  const env = data?.environment;
  return verifierFor(env).verifyAndDecodeNotification(signedPayload);
}
