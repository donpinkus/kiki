/**
 * Provision-time policy hook.
 *
 * v1: every user is allowed to fall back to on-demand when spot is exhausted.
 * When paid tiers land (Workstream 8), this is the seam where free vs paid
 * users get different fallback behavior — e.g. free users stay spot-only and
 * see an "unavailable, try later" error during spot outages.
 */

export interface ProvisionPolicy {
  /**
   * True if this identity is allowed to be provisioned on an on-demand pod
   * (~$0.45/hr more than spot) when spot capacity is exhausted.
   */
  allowsOnDemand(identity: { userId: string; source: 'jwt' | 'legacy_session' }): Promise<boolean>;
}

export const allowAllPolicy: ProvisionPolicy = {
  allowsOnDemand: async () => true,
};

let currentPolicy: ProvisionPolicy = allowAllPolicy;

export function setPolicy(policy: ProvisionPolicy): void {
  currentPolicy = policy;
}

export function getPolicy(): ProvisionPolicy {
  return currentPolicy;
}
