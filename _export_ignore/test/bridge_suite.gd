extends RefCounted
## The bridge's listener and config tests. Run them with bridge_test.gd, headless or through
## the editor console's `test`. Each test returns "" on success or the problem.

const Bridge = preload("res://addons/_lib/mcp_sh_bridge/src/bridge.gd")
const BridgeConfig = preload("res://addons/_lib/mcp_sh_bridge/src/bridge_config.gd")

const TESTS = ["test_hello_and_invoke", "test_wrong_token", "test_free_port", "test_split_utf8",
		"test_oversized_request", "test_idle_connection", "test_connection_flood",
		"test_config_keys", "test_command_roots", "test_apply_to", "test_cancel_options",
		"test_client_disconnect"]

var tree: SceneTree
var bridge: Node
var failures := 0


## A host with one command, say (echo is excluded by default), which returns its arguments and stdin.
class FakeHost:
	extends RefCounted

	func host_commands() -> Array:
		return [{"name": "say", "summary": "print args and stdin"}]

	func host_help(name: String) -> String:
		return "say ARGS..." if name == "say" else ""

	func host_run(argv: Array, stdin: String = "") -> Dictionary:
		return {"stdout": " ".join(argv.slice(1)) + stdin, "stderr": "", "exit_code": 0}


## A host with cancellation support: keeps the opts it was given and, for `spin`, runs until
## cancel_check gives a reason (or 5 s pass).
class CancelHost:
	extends RefCounted
	var opts := {}
	var reason := ""

	func host_commands() -> Array:
		return [{"name": "spin", "summary": "run until cancelled"}]

	func host_help(_name: String) -> String:
		return ""

	func host_run(argv: Array, _stdin: String = "", run_opts: Dictionary = {}) -> Dictionary:
		opts = run_opts
		if argv.size() > 1 and argv[1] == "quick":
			return {"stdout": "ok", "stderr": "", "exit_code": 0}
		var check = run_opts.get("cancel_check")
		var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 5000:
			if check is Callable:
				reason = check.call()
				if not reason.is_empty():
					break
			await (Engine.get_main_loop() as SceneTree).process_frame
		return {"stdout": "", "stderr": reason, "exit_code": 130}


func _init(scene_tree: SceneTree) -> void:
	tree = scene_tree


## Runs every test on its own bridge. Returns {result: failure count, output: lines}.
func run() -> Dictionary:
	var output := []
	for test in TESTS:
		_start_bridge()
		# Test functions are untyped so a script error inside one returns null, not "".
		var result: Variant = await call(test)
		var problem: String = result if result is String else "script error (see the log above)"
		output.append(("ok   " + test) if problem.is_empty() else ("FAIL %s: %s" % [test, problem]))
		if not problem.is_empty():
			failures += 1
		bridge.stop()
		bridge.free()
	output.append("%d failed" % failures)
	return {"result": failures, "output": output}


func _start_bridge(port: int = -1) -> void:
	bridge = Bridge.new()
	bridge.host = FakeHost.new()
	bridge.token = "secret"
	bridge.port = port
	bridge.autostart = false
	tree.root.add_child(bridge)
	bridge.start()


func request(chunks: Array, timeout_ms: int = 3000) -> Dictionary:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", bridge.get_port())
	var pending := []
	for chunk: Variant in chunks:
		pending.append(chunk if chunk is PackedByteArray else str(chunk).to_utf8_buffer())
	var offset := 0
	var received := PackedByteArray()
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			# Partial writes, one slice per frame: put_data blocks until everything is sent, and
			# the bridge reading the other end runs on this same thread.
			if not pending.is_empty():
				var data: PackedByteArray = pending[0]
				var wrote: Array = peer.put_partial_data(data.slice(offset, offset + 65536))
				if wrote[0] == OK:
					offset += int(wrote[1])
				if offset >= data.size():
					pending.pop_front()
					offset = 0
			var available := peer.get_available_bytes()
			if available > 0:
				received.append_array(peer.get_data(available)[1])
				if received.find(10) != -1:
					break
		elif status != StreamPeerTCP.STATUS_CONNECTING:
			break
		await tree.process_frame
	peer.disconnect_from_host()
	if received.is_empty():
		return {"_closed": true}
	return JSON.parse_string(received.get_string_from_utf8())


func line(payload: Dictionary) -> String:
	return JSON.stringify(payload) + "\n"


func test_hello_and_invoke():
	var hello := await request([line({"id": 1, "token": "secret", "method": "hello"})])
	if hello.get("commands", []).size() != 1:
		return "hello: %s" % hello
	var out := await request([line({"id": 2, "token": "secret", "method": "invoke", "cmd": "say", "args": ["a", "b"], "stdin": "!"})])
	return "" if out.get("stdout") == "a b!" else "invoke: %s" % out


func test_wrong_token():
	var out := await request([line({"id": 1, "token": "nope", "method": "hello"})])
	return "" if out.get("error") == "Unauthorized" else str(out)


func test_free_port():
	if bridge.get_port() <= 0:
		return "no port chosen"
	var other := Bridge.new()
	other.host = FakeHost.new()
	other.port = -1
	other.autostart = false
	tree.root.add_child(other)
	var err: int = other.start()
	var port: int = other.get_port()
	other.stop()
	other.free()
	if err != OK or port == bridge.get_port():
		return "second bridge: err %d port %d" % [err, port]
	return ""


## A multi-byte character split across two reads must arrive intact.
func test_split_utf8():
	var text := "naïve “quotes” ✓"
	var bytes := line({"id": 1, "token": "secret", "method": "invoke", "cmd": "say", "args": [text]}).to_utf8_buffer()
	var cut := bytes.find("ï".to_utf8_buffer()[0]) + 1 # inside the two-byte ï
	var out := await request([bytes.slice(0, cut), bytes.slice(cut)])
	return "" if out.get("stdout") == text else "got %s" % out


func test_oversized_request():
	bridge.max_request_bytes = 4096
	var big := PackedByteArray()
	big.resize(8192)
	big.fill(65)
	var out := await request([big])
	return "" if out.get("error") == "Request too large" else str(out)


func test_idle_connection():
	bridge.idle_timeout_ms = 200
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", bridge.get_port())
	var start := Time.get_ticks_msec()
	var connected := false
	while Time.get_ticks_msec() - start < 3000:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED and not connected:
			connected = true
			peer.put_data("{\"id\":1".to_utf8_buffer()) # never finishes the line
		elif connected and status != StreamPeerTCP.STATUS_CONNECTED:
			return ""
		# A closed socket can still read as connected until a read sees EOF.
		if connected and peer.get_available_bytes() == 0 and Time.get_ticks_msec() - start > 600:
			var probe: Array = peer.get_partial_data(1)
			if probe[0] != OK:
				return ""
		await tree.process_frame
	return "not closed within 3 s"


func test_connection_flood():
	bridge.max_connections = 4
	var peers := []
	for i in 12:
		var peer := StreamPeerTCP.new()
		peer.connect_to_host("127.0.0.1", bridge.get_port())
		peers.append(peer)
	for i in 10:
		await tree.process_frame
		for peer: StreamPeerTCP in peers:
			peer.poll()
	var held: int = bridge._conns.size()
	for peer: StreamPeerTCP in peers:
		peer.disconnect_from_host()
	for i in 5:
		await tree.process_frame
	if held > 4:
		return "held %d connections" % held
	var out := await request([line({"id": 1, "token": "secret", "method": "hello"})])
	return "" if out.has("commands") else "no service after the flood: %s" % out


func test_config_keys():
	var path := ProjectSettings.globalize_path("user://mcp_sh_bridge_test/bridge.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"port": -1, "maxRequestBytes": 2048, "maxConnections": 3,
			"idleTimeoutMs": 500, "commandDirs": ["cmds"], "exclude": ["extra"]}))
	file.close()
	var cfg = BridgeConfig.new()
	cfg._apply_file(path)
	DirAccess.remove_absolute(path)
	var got := [cfg.port, cfg.max_request_bytes, cfg.max_connections, cfg.idle_timeout_ms]
	if got != [-1, 2048, 3, 500]:
		return "config read %s" % str(got)
	if cfg.command_dirs != PackedStringArray([path.get_base_dir().path_join("cmds")]):
		return "commandDirs not resolved against the file: %s" % cfg.command_dirs
	if not "extra" in cfg.exclude or not "os" in cfg.exclude:
		return "exclude should add to the defaults: %s" % cfg.exclude
	return ""


## Each layer's folder is a command root, added ahead of its commandDirs whether or not it
## exists yet (the host lists it on each request). Records the directories a config adds.
class DirRecorder:
	extends RefCounted
	var dirs := PackedStringArray()

	func add_default_dirs() -> void:
		dirs.append("<defaults>")

	func add_command_root(root: String) -> void:
		dirs.append("root:" + root)

	func add_command_dir(dir: String) -> void:
		dirs.append(dir)

	func add_command(_path: String, _name: String = "") -> void:
		pass


## An older gdsh copy without add_command_root or add_default_dirs.
class OldDirRecorder:
	extends RefCounted
	var dirs := PackedStringArray()

	func add_command_dir(dir: String) -> void:
		dirs.append(dir)

	func add_command(_path: String, _name: String = "") -> void:
		pass


func _dirs_added(cfg, command_roots: bool, host = null) -> PackedStringArray:
	if host == null:
		host = DirRecorder.new()
	cfg.add_commands_to(host, command_roots)
	return host.dirs


func test_command_roots():
	var root := ProjectSettings.globalize_path("user://mcp_sh_bridge_test_cfg")
	var layer := root.path_join("godot")
	var commands := layer.path_join(BridgeConfig.COMMANDS_DIR)
	var lib := layer.path_join("lib")
	var project := BridgeConfig.project_path().get_base_dir()
	var previous := OS.get_environment("MCP_SH_CONFIG_DIR")
	OS.set_environment("MCP_SH_CONFIG_DIR", root)
	var before := _dirs_added(BridgeConfig.load_config(), true)
	DirAccess.make_dir_recursive_absolute(commands)
	var file := FileAccess.open(layer.path_join(BridgeConfig.FILE_NAME), FileAccess.WRITE)
	file.store_string(JSON.stringify({"commandDirs": ["lib"], "newCommands": "gdsh"}))
	file.close()
	var cfg = BridgeConfig.load_config()
	OS.set_environment("MCP_SH_CONFIG_DIR", previous)
	var old_host := _dirs_added(cfg, true, OldDirRecorder.new())
	DirAccess.remove_absolute(layer.path_join(BridgeConfig.FILE_NAME))
	DirAccess.remove_absolute(commands)
	DirAccess.remove_absolute(layer)
	DirAccess.remove_absolute(root)
	if before != PackedStringArray(["<defaults>", "root:" + layer, "root:" + project]):
		return "a missing layer folder is still a root: %s" % before
	var plain := _dirs_added(cfg, false)
	if plain != PackedStringArray([lib]):
		return "without command_roots only commandDirs are added: %s" % plain
	var with_roots := _dirs_added(cfg, true)
	if with_roots != PackedStringArray(["<defaults>", "root:" + layer, lib, "root:" + project]):
		return "with command_roots: gdsh's defaults, then each layer's root and commandDirs: %s" % with_roots
	if old_host != PackedStringArray([commands, lib]):
		return "an older gdsh gets the commands/ folders that exist: %s" % old_host
	if cfg.command_dirs != PackedStringArray([lib]):
		return "command_dirs holds only bridge.json's commandDirs: %s" % cfg.command_dirs
	return ""


func test_apply_to():
	var cfg = BridgeConfig.new()
	cfg.token = "t"
	cfg.max_connections = 2
	cfg.include = PackedStringArray(["echo"])
	var other := Bridge.new()
	cfg.apply_to(other)
	var got := [other.token, other.max_connections, other.is_excluded("echo"), other.is_excluded("os")]
	other.free()
	return "" if got == ["t", 2, false, true] else "applied %s" % str(got)


## timeout_ms and max_output reach a host that takes opts, with a disconnect check; none are
## made up when the request doesn't send them.
func test_cancel_options():
	var host := CancelHost.new()
	bridge.host = host
	var out := await request([line({"id": 1, "token": "secret", "method": "invoke", "cmd": "spin", "args": ["quick"], "timeout_ms": 1500, "max_output": 99})])
	if out.get("stdout") != "ok":
		return "invoke: %s" % out
	if host.opts.get("timeout_ms") != 1500 or host.opts.get("max_output") != 99 or not host.opts.get("cancel_check") is Callable:
		return "opts: %s" % host.opts
	await request([line({"id": 2, "token": "secret", "method": "invoke", "cmd": "spin", "args": ["quick"]})])
	if host.opts.has("timeout_ms") or host.opts.has("max_output"):
		return "defaults should add no limits: %s" % host.opts
	return ""


## The client hanging up mid-command is what mcp-sh does on timeout; the host's check sees it.
func test_client_disconnect():
	var host := CancelHost.new()
	bridge.host = host
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", bridge.get_port())
	var start := Time.get_ticks_msec()
	var sent := false
	while Time.get_ticks_msec() - start < 3000:
		peer.poll()
		if not sent and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.put_data(line({"id": 1, "token": "secret", "method": "invoke", "cmd": "spin"}).to_utf8_buffer())
			sent = true
			start = Time.get_ticks_msec()
		elif sent and Time.get_ticks_msec() - start > 200:
			break
		await tree.process_frame
	peer.disconnect_from_host()
	var gone := Time.get_ticks_msec()
	while host.reason.is_empty() and Time.get_ticks_msec() - gone < 3000:
		await tree.process_frame
	if host.reason != "client disconnected":
		return "host never saw the disconnect (reason %s)" % [host.reason if not host.reason.is_empty() else "none"]
	return ""
