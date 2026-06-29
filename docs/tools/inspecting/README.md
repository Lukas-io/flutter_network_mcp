# Inspecting one request

Once you have an id (from [`finding/`](../finding/) or [`what-went-wrong/`](../what-went-wrong/)), these read it.

- [`network_get`](network_get.md) — full headers + truncated body for one id.
- [`network_body`](network_body.md) — byte-range body fetch when `network_get` reports `truncated:true`.
- [`network_body_outline`](network_body_outline.md) — structural skeleton of a large body (keys/types/sizes, no values) so you drill the right branch.
- [`network_body_query`](network_body_query.md) — search/extract WITHIN one body: regex grep or a JSON path, returning only the matching slice(s).
