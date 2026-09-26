# flutter_network_mcp has moved

This project is now **glint_network**, the network toolset of [glint](https://github.com/Lukas-io/glint). It lives at [`packages/glint_network`](https://github.com/Lukas-io/glint/tree/main/packages/glint_network) with its full history, and new releases, issues and pull requests go there.

This repository is archived and read-only.

## Switching over

```bash
dart pub global deactivate flutter_network_mcp
dart pub global activate -s git https://github.com/Lukas-io/glint.git --git-path packages/glint_network
glint_network install
```

Then, in your MCP config, rename the `flutter-network` entry to `glint-network` and set its `command` to `glint_network`. Your captures stay where they are.

- The old `flutter_network_mcp` command still works, as an alias.
- `FLUTTER_NETWORK_MCP_*` environment variables still work; their new names are `GLINT_NETWORK_*`.
- Tool names and arguments are unchanged. Agents see them as `glint-network__<tool>` once the entry is renamed.

The last release from this repository is [v0.11.0](https://github.com/Lukas-io/flutter_network_mcp/releases/tag/v0.11.0).
