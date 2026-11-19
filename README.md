# mcp_sh_bridge

A loopback TCP listener that speaks the [mcp-sh](https://github.com/brohd11/mcp-sh) host
protocol, so [mcp-sh-godot](https://github.com/brohd11/mcp-sh-godot) can run commands in the
Godot editor or a running game. The shell itself (pipes, loops, jq) runs in the mcp-sh-godot
binary. Godot only lists its top-level commands and runs one at a time.

It has no dependencies. The commands come from a host, which is any object with
`host_commands()`, `host_help(name)` and `host_run(argv, stdin)`, such as a `GDSh.Host`.

- [Editor Console](https://github.com/brohd11/Godot-Editor-Console) requires it and serves the
  console's commands after `mcp --start` (add it to the console's startup commands).
- mcp-sh-godot's editor addon uses it to serve plain gdsh in projects without Editor Console.
- A game adds the node itself:

```gdscript
const McpShBridge = preload("res://addons/_lib/mcp_sh_bridge/src/bridge.gd")

func _ready():
    var bridge = McpShBridge.new()
    bridge.host = my_host        # optional: plain gdsh (found by class name) when null
    add_child(bridge)
```

- It listens on 127.0.0.1 only: `9510` in the editor, `9511` in a game, `port = -1` for any
  free port (`get_port()` says which).
- Release builds don't listen unless `serve_in_release` is set, because commands can run any
  code.
- `token`, `exclude`/`include` and the listener bounds (`max_request_bytes`,
  `max_connections`, `idle_timeout_ms`) are exports. See the comments in `src/bridge.gd`.

`src/bridge_config.gd` reads mcp-sh-godot's `bridge.json` (user file, then project file).
`apply_to(bridge)` copies the listener settings, and `add_commands_to(host)` adds
`commandDirs`/`commands`. `add_commands_to(host, true)` also adds each layer's `commands/`
folder (`~/.mcp-sh/godot/commands`, `res://.mcp-sh/godot/commands`) when it exists. Editor
Console and the mcp-sh-godot addon pass `true`; a game serving its own commands leaves it off,
so it never picks up the user's. The keys are documented in the mcp-sh-godot README.

## Tests

```sh
python3 addons/_lib/mcp_sh_bridge/_export_ignore/test/run_headless.py --godot godot
```

In Editor Console: `test mcp_sh_bridge`.
