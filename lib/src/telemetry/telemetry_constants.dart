/// Compile-time constants for the telemetry layer.
///
/// These are intentionally NOT read from environment / config — they're
/// baked into the binary so users can audit what their install will do
/// just by inspecting this file (or running `flutter_network_mcp audit
/// show` to see the payloads themselves).
library;

/// Collector POST endpoint. Empty string = local-only mode (the binary
/// writes the tamper-evident audit log but never makes a network attempt).
/// Live as of 0.8.12: the Cloudflare Worker + D1 collector in `collector/`
/// is deployed, so crash reports and usage rollups now POST here (the audit
/// log still records byte-for-byte what was sent), but only for users who
/// set `FLUTTER_NETWORK_MCP_TELEMETRY=on`. The worker routes by payload
/// `kind`; see `collector/README.md`.
const String kCollectorEndpoint =
    'https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry';

/// Wire deadline for the POST attempt. Best-effort: a 3s budget covers
/// healthy networks and leaves the MCP shutdown path free to exit even
/// if the collector is down.
const Duration kTelemetryTimeout = Duration(seconds: 3);

/// Max stack frames in the payload. Trim depth keeps the payload small
/// + privacy footprint bounded.
const int kStackHeadFrames = 8;

/// Max chars in the `errorMessage` field. Trims long Dart error strings
/// (some carry inline JSON or stack-trace fragments) before they hit
/// the wire.
const int kErrorMessageMaxChars = 200;

/// User-Agent for the HTTPS request. Identifies the client so the
/// collector can rate-limit by UA pattern if a future MCP fork misuses
/// the endpoint.
const String kTelemetryUserAgent = 'flutter_network_mcp-telemetry';
