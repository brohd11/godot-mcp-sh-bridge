extends SceneTree
## Headless: python3 addons/_lib/mcp_sh_bridge/_export_ignore/test/run_headless.py
## Editor console: `test mcp_sh_bridge` runs the same suite.
const Suite = preload("res://addons/_lib/mcp_sh_bridge/_export_ignore/test/bridge_suite.gd")


func _initialize():
	_run.call_deferred()


func _run():
	var res = await run_tests()
	print("\n".join(res.output))
	quit(0 if res.result == 0 else 1)


## Entry for the editor console `test` command.
static func run_tests() -> Dictionary:
	return await Suite.new(Engine.get_main_loop()).run()
