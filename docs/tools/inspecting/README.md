# Inspecting one request

Once you have an id (from [`finding/`](../finding/) or [`what-went-wrong/`](../what-went-wrong/)), these read it.

- [`network_get`](network_get.md) — full headers + truncated body for one id.
- [`network_body`](network_body.md) — byte-range body fetch when `network_get` reports `truncated:true`.
