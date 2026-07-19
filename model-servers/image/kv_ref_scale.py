"""Sketch-adherence: reference-token K/V scaling for the KV pipeline.

The "follow my sketch <-> follow my prompt" dial. The Flux2KleinKVPipeline
extracts reference-token K/V once at step 0 (`kv_cache_mode="extract"`) and
replays them from the cache for steps 1+. We subclass the two KV attention
processors and multiply the reference-token K/V slices by a runtime scale
factor at the extract point — BEFORE both the cache store and the step-0
attention — so a single insertion covers every step: the cache stores the
scaled tensors, and cached-mode replay needs no changes at all.

scale=1.0 is numerically a no-op (multiplying by exactly 1.0), >1 makes the
generation "listen" to the sketch harder, <1 frees the prompt. Same math as
ComfyUI-Flux2Klein-Enhancer's Flux2KleinRefLatentController (scale k AND v,
post-norm/RoPE, all blocks uniformly).

torch.compile: the scale lives in a persistent 1-element CUDA tensor mutated
in-place via `fill_()` OUTSIDE the graph. Dynamo lifts tensor attributes as
graph inputs guarded on shape/dtype/device — not value — so slider changes
don't recompile. The multiply is UNCONDITIONAL inside the extract branch (no
`if scale != 1` value guard) and out-of-place (torch.cat, no in-place slice
mutation graph breaks).

Forked bodies track diffusers @ 1aadc65cacf94515e9c9a040def3e9a9e14d32c5
(model-servers/requirements.txt pin) — revisit on any diffusers bump.
"""

import torch
from diffusers.models.transformers.transformer_flux2 import (
    Flux2KVAttnProcessor,
    Flux2KVParallelSelfAttnProcessor,
    _flux2_kv_causal_attention,
    _get_qkv_projections,
    apply_rotary_emb,
    dispatch_attention_fn,
)

# Lazily created on first install() so importing this module never touches CUDA.
_ref_scale: torch.Tensor | None = None


def set_scale(value: float) -> None:
    """Update the adherence scale (call under the pipeline lock)."""
    if _ref_scale is not None:
        _ref_scale.fill_(value)


def get_scale() -> float:
    return float(_ref_scale.item()) if _ref_scale is not None else 1.0


def _scaled(key: torch.Tensor, value: torch.Tensor, ref_start: int, ref_end: int):
    """Return (key, value) with the reference-token slice scaled. Out-of-place."""
    s = _ref_scale
    key = torch.cat([key[:, :ref_start], key[:, ref_start:ref_end] * s, key[:, ref_end:]], dim=1)
    value = torch.cat([value[:, :ref_start], value[:, ref_start:ref_end] * s, value[:, ref_end:]], dim=1)
    return key, value


class ScaledKVAttnProcessor(Flux2KVAttnProcessor):
    """Double-stream processor with ref K/V scaling in extract mode."""

    def __call__(
        self,
        attn,
        hidden_states: torch.Tensor,
        encoder_hidden_states: torch.Tensor = None,
        attention_mask: torch.Tensor | None = None,
        image_rotary_emb: torch.Tensor | None = None,
        kv_cache=None,
        kv_cache_mode: str | None = None,
        num_ref_tokens: int = 0,
    ) -> torch.Tensor:
        query, key, value, encoder_query, encoder_key, encoder_value = _get_qkv_projections(
            attn, hidden_states, encoder_hidden_states
        )

        query = query.unflatten(-1, (attn.heads, -1))
        key = key.unflatten(-1, (attn.heads, -1))
        value = value.unflatten(-1, (attn.heads, -1))

        query = attn.norm_q(query)
        key = attn.norm_k(key)

        if attn.added_kv_proj_dim is not None:
            encoder_query = encoder_query.unflatten(-1, (attn.heads, -1))
            encoder_key = encoder_key.unflatten(-1, (attn.heads, -1))
            encoder_value = encoder_value.unflatten(-1, (attn.heads, -1))

            encoder_query = attn.norm_added_q(encoder_query)
            encoder_key = attn.norm_added_k(encoder_key)

            query = torch.cat([encoder_query, query], dim=1)
            key = torch.cat([encoder_key, key], dim=1)
            value = torch.cat([encoder_value, value], dim=1)

        if image_rotary_emb is not None:
            query = apply_rotary_emb(query, image_rotary_emb, sequence_dim=1)
            key = apply_rotary_emb(key, image_rotary_emb, sequence_dim=1)

        num_txt_tokens = encoder_hidden_states.shape[1] if encoder_hidden_states is not None else 0

        # --- Kiki adherence hook: scale ref K/V before store + attention ---
        if kv_cache_mode == "extract" and num_ref_tokens > 0:
            key, value = _scaled(key, value, num_txt_tokens, num_txt_tokens + num_ref_tokens)
        # -------------------------------------------------------------------

        if kv_cache_mode == "extract" and kv_cache is not None and num_ref_tokens > 0:
            ref_start = num_txt_tokens
            ref_end = num_txt_tokens + num_ref_tokens
            kv_cache.store(key[:, ref_start:ref_end].clone(), value[:, ref_start:ref_end].clone())

        if kv_cache_mode == "extract" and num_ref_tokens > 0:
            hidden_states = _flux2_kv_causal_attention(
                query, key, value, num_txt_tokens, num_ref_tokens, backend=self._attention_backend
            )
        elif kv_cache_mode == "cached" and kv_cache is not None:
            hidden_states = _flux2_kv_causal_attention(
                query, key, value, num_txt_tokens, 0, kv_cache=kv_cache, backend=self._attention_backend
            )
        else:
            hidden_states = dispatch_attention_fn(
                query,
                key,
                value,
                attn_mask=attention_mask,
                backend=self._attention_backend,
                parallel_config=self._parallel_config,
            )

        hidden_states = hidden_states.flatten(2, 3)
        hidden_states = hidden_states.to(query.dtype)

        if encoder_hidden_states is not None:
            encoder_hidden_states, hidden_states = hidden_states.split_with_sizes(
                [encoder_hidden_states.shape[1], hidden_states.shape[1] - encoder_hidden_states.shape[1]], dim=1
            )
            encoder_hidden_states = attn.to_add_out(encoder_hidden_states)

        hidden_states = attn.to_out[0](hidden_states)
        hidden_states = attn.to_out[1](hidden_states)

        if encoder_hidden_states is not None:
            return hidden_states, encoder_hidden_states
        return hidden_states


class ScaledKVParallelSelfAttnProcessor(Flux2KVParallelSelfAttnProcessor):
    """Single-stream (parallel) processor with ref K/V scaling in extract mode."""

    def __call__(
        self,
        attn,
        hidden_states: torch.Tensor,
        attention_mask: torch.Tensor | None = None,
        image_rotary_emb: torch.Tensor | None = None,
        kv_cache=None,
        kv_cache_mode: str | None = None,
        num_txt_tokens: int = 0,
        num_ref_tokens: int = 0,
    ) -> torch.Tensor:
        hidden_states_proj = attn.to_qkv_mlp_proj(hidden_states)
        qkv, mlp_hidden_states = torch.split(
            hidden_states_proj, [3 * attn.inner_dim, attn.mlp_hidden_dim * attn.mlp_mult_factor], dim=-1
        )

        query, key, value = qkv.chunk(3, dim=-1)

        query = query.unflatten(-1, (attn.heads, -1))
        key = key.unflatten(-1, (attn.heads, -1))
        value = value.unflatten(-1, (attn.heads, -1))

        query = attn.norm_q(query)
        key = attn.norm_k(key)

        if image_rotary_emb is not None:
            query = apply_rotary_emb(query, image_rotary_emb, sequence_dim=1)
            key = apply_rotary_emb(key, image_rotary_emb, sequence_dim=1)

        # --- Kiki adherence hook: scale ref K/V before store + attention ---
        if kv_cache_mode == "extract" and num_ref_tokens > 0:
            key, value = _scaled(key, value, num_txt_tokens, num_txt_tokens + num_ref_tokens)
        # -------------------------------------------------------------------

        if kv_cache_mode == "extract" and kv_cache is not None and num_ref_tokens > 0:
            ref_start = num_txt_tokens
            ref_end = num_txt_tokens + num_ref_tokens
            kv_cache.store(key[:, ref_start:ref_end].clone(), value[:, ref_start:ref_end].clone())

        if kv_cache_mode == "extract" and num_ref_tokens > 0:
            attn_output = _flux2_kv_causal_attention(
                query, key, value, num_txt_tokens, num_ref_tokens, backend=self._attention_backend
            )
        elif kv_cache_mode == "cached" and kv_cache is not None:
            attn_output = _flux2_kv_causal_attention(
                query, key, value, num_txt_tokens, 0, kv_cache=kv_cache, backend=self._attention_backend
            )
        else:
            attn_output = dispatch_attention_fn(
                query,
                key,
                value,
                attn_mask=attention_mask,
                backend=self._attention_backend,
                parallel_config=self._parallel_config,
            )

        attn_output = attn_output.flatten(2, 3)
        attn_output = attn_output.to(query.dtype)

        mlp_hidden_states = attn.mlp_act_fn(mlp_hidden_states)

        hidden_states = torch.cat([attn_output, mlp_hidden_states], dim=-1)
        hidden_states = attn.to_out(hidden_states)

        return hidden_states


def install(transformer) -> None:
    """Swap the KV pipeline's attention processors for the scaled variants.

    Call after from_pretrained (the pipeline's __init__ installed the stock KV
    processors) and BEFORE torch.compile, so the multiply is part of the
    compiled graph. Mirrors Flux2KleinKVPipeline._set_kv_attn_processors.
    """
    global _ref_scale
    if _ref_scale is None:
        _ref_scale = torch.ones(1, device="cuda", dtype=transformer.dtype)
    for block in transformer.transformer_blocks:
        block.attn.set_processor(ScaledKVAttnProcessor())
    for block in transformer.single_transformer_blocks:
        block.attn.set_processor(ScaledKVParallelSelfAttnProcessor())
