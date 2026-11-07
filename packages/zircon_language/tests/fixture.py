"""Deterministic stdio LSP subprocess used by Zig integration tests."""
import json
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
if mode == "early":
    sys.stderr.write("fixture exited early\n")
    sys.exit(3)
if mode == "blocked":
    # Exercise forced shutdown of an unresponsive owned process.
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(60)
if mode == "malformed":
    sys.stdout.buffer.write(b"Content-Length: -4\r\n\r\n")
    sys.stdout.buffer.flush()
    while True:
        time.sleep(60)

def send(value):
    body = json.dumps(value, ensure_ascii=False).encode("utf-8")
    data = ("Content-Length: %d\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" % len(body)).encode() + body
    for offset in range(0, len(data), 7):
        sys.stdout.buffer.write(data[offset:offset + 7])
        sys.stdout.buffer.flush()

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    return json.loads(sys.stdin.buffer.read(length))

mode = sys.argv[1] if len(sys.argv) > 1 else "full"
opened = {}
completions = []
initialized = False
shutdown = False
while True:
    message = read()
    if message is None:
        sys.exit(0)
    method = message.get("method")
    params = message.get("params", {})
    if method == "initialize":
        sys.stderr.write("fixture stderr " + "x" * 80000 + "\n")
        sys.stderr.flush()
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {"textDocumentSync": 2 if mode == "incremental" else 1, "positionEncoding": "utf-16", "completionProvider": {}}}})
    elif method == "initialized":
        assert isinstance(message.get("params"), dict), "initialized params must be a JSON object"
        initialized = True
        send({"jsonrpc": "2.0", "id": "configuration-1", "method": "workspace/configuration", "params": {"items": [{"section": "fixture"}]}})
        send({"jsonrpc": "2.0", "id": "progress-1", "method": "window/workDoneProgress/create", "params": {"token": "fixture-progress"}})
        send({"jsonrpc": "2.0", "id": "server-1", "method": "workspace/unsupported", "params": {}})
    elif method == "textDocument/didOpen":
        assert initialized
        document = params["textDocument"]
        opened[document["uri"]] = document
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document["uri"], "version": document["version"], "diagnostics": [{"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}}, "severity": 2, "message": "emoji warning", "source": "fixture"}]}})
    elif method == "textDocument/didChange":
        document = params["textDocument"]
        old = opened[document["uri"]]
        assert document["version"] > old["version"]
        if mode == "incremental":
            assert "range" in params["contentChanges"][0]
        old.update(document)
        old["text"] = params["contentChanges"][0]["text"] if "range" not in params["contentChanges"][0] else old["text"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document["uri"], "version": document["version"], "diagnostics": []}})
    elif method == "textDocument/completion":
        assert params["position"]["character"] == 3
        completions.append(message)
        if len(completions) == 2 or mode == "host":
            for request in reversed(completions):
                send({"jsonrpc": "2.0", "id": request["id"], "result": {"isIncomplete": False, "items": [{"label": "answer🙂", "insertText": "answer", "detail": "fixture completion", "textEdit": {"range": {"start": {"line": 0, "character": 3}, "end": {"line": 0, "character": 3}}, "newText": "answer"}}]}})
            completions.clear()
    elif method == "textDocument/didClose":
        opened.pop(params["textDocument"]["uri"], None)
    elif method == "shutdown":
        shutdown = True
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
    elif method == "exit":
        sys.exit(0 if shutdown and not opened else 7)
    elif method == "$/cancelRequest":
        completions = [item for item in completions if item["id"] != params["id"]]
    elif message.get("id") == "server-1":
        assert message["error"]["code"] == -32601
    elif message.get("id") == "configuration-1":
        assert message["result"] == [None]
    elif message.get("id") == "progress-1":
        assert message["result"] is None
