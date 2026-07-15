/**
 * BlobStore — abstraction over where drawing thumbnails / generated images /
 * (later) videos live. v1 implementation writes to a Railway persistent volume
 * mounted at config.BLOB_DIR. The interface is deliberately tiny so swapping to
 * S3/R2 later is a one-file change with zero data-model impact (Postgres only
 * ever stores the returned `key`).
 *
 * Keys are relative POSIX-ish paths, e.g. `drawings/<drawing_id>/thumb.jpg`.
 * `urlFor` returns an app-relative URL served by the /blobs route (admin-gated).
 */

import { mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { dirname, join, normalize, resolve, sep } from 'node:path';
import { config } from './config.js';

export interface BlobStore {
  put(key: string, bytes: Buffer): Promise<void>;
  get(key: string): Promise<Buffer>;
  /** Idempotent — deleting a missing key is a no-op (retention pruning). */
  delete(key: string): Promise<void>;
  urlFor(key: string): string;
}

/** Reject keys that try to escape the blob root (.. traversal, absolute paths). */
function safeResolve(root: string, key: string): string {
  const cleaned = normalize(key).replace(/^(\.\.(\/|\\|$))+/, '');
  const resolved = join(root, cleaned);
  if (!resolved.startsWith(root + sep) && resolved !== root) {
    throw new Error(`Unsafe blob key: ${key}`);
  }
  return resolved;
}

class VolumeBlobStore implements BlobStore {
  private readonly root: string;
  constructor(root: string) {
    // Resolve to absolute so the traversal check in safeResolve is reliable
    // regardless of a relative BLOB_DIR (e.g. "./blobs") or the process cwd.
    this.root = resolve(root);
  }

  async put(key: string, bytes: Buffer): Promise<void> {
    const path = safeResolve(this.root, key);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, bytes);
  }

  async get(key: string): Promise<Buffer> {
    return readFile(safeResolve(this.root, key));
  }

  async delete(key: string): Promise<void> {
    await rm(safeResolve(this.root, key), { force: true });
  }

  urlFor(key: string): string {
    return `/blobs/${key}`;
  }
}

export const blobStore: BlobStore = new VolumeBlobStore(config.BLOB_DIR);
