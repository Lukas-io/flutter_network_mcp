/// Compile-time constants for the telemetry layer.
///
/// These are intentionally NOT read from environment / config — they're
/// baked into the binary so users can audit what their install will do
/// just by inspecting this file (or running `flutter_network_mcp audit
/// show` to see the payloads themselves).
library;

/// Public HMAC salt. Every install uses this same value to compute its
/// `machineHash`, so the collector can dedupe machines without learning
/// anything identifying. The collector knows the salt (this is just the
/// public half of the HMAC key pair); the maintainer holds the
/// corresponding secret on the collector side if/when payload
/// authentication is added later.
///
/// Generated once at the 0.7.1 release via `openssl rand -hex 32`. DO
/// NOT change without coordinated collector update — every install
/// computes its `machineHash` against THIS salt, so changing the salt
/// resets the dedupe view.
const String kPublicSalt =
    '761d2c3db2b2719c04ad002499704b7e094048c57046457c545105be31de8d11';

/// Collector POST endpoint. Empty string = local-only mode (the binary
/// writes the tamper-evident audit log but never makes a network attempt).
/// Live as of 0.8.12: the Cloudflare Worker + D1 collector in `collector/`
/// is deployed, so crash reports and usage rollups now POST here (the audit
/// log still records byte-for-byte what was sent). Opt out with
/// `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`. The worker routes by payload
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
