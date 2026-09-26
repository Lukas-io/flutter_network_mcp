# ⚠️ flutter_network_mcp is deprecated

> [!CAUTION]
> **flutter_network_mcp stops working on 26 December 2026.**
> It is now **glint_network**, the network toolset of [glint](https://github.com/Lukas-io/glint), and all new releases ship from there.
> After that date this repository is archived, `flutter_network_mcp update` stops finding new versions, and the `flutter_network_mcp` command and `FLUTTER_NETWORK_MCP_*` variables are removed.

## Move over in two minutes

1. **Update.** Run this once; it moves your install to the glint repository and keeps your captures, settings and native build:
   ```bash
   flutter_network_mcp update
   ```
   Not installed yet? Install glint_network directly instead:
   ```bash
   dart pub global activate -s git https://github.com/Lukas-io/glint.git --git-path packages/glint_network
   glint_network install
   ```
2. **Rename the server in your MCP config** (`~/.claude.json`, `.mcp.json`, or your client's equivalent): the `flutter-network` entry becomes `glint-network`, and its command becomes `glint_network`.
   ```json
   {
     "mcpServers": {
       "glint-network": { "type": "stdio", "command": "glint_network" }
     }
   }
   ```
3. **Rename any environment variables** from `FLUTTER_NETWORK_MCP_*` to `GLINT_NETWORK_*`.
4. **Restart your agent host.**

Until you finish, the server itself tells your agent what is left, so you don't have to remember. Tool names and arguments are unchanged; agents see them as `glint-network__<tool>` after step 2.

## Where things are now

- Code, docs and releases: [`Lukas-io/glint/packages/glint_network`](https://github.com/Lukas-io/glint/tree/main/packages/glint_network)
- Issues: [Lukas-io/glint/issues](https://github.com/Lukas-io/glint/issues), label `network`
- History: every commit from this repository is in glint, under `packages/glint_network`.

This repository's code is glint_network 0.12.0 under its old name, so that `flutter_network_mcp update` can carry existing installs across.
