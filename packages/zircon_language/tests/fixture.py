"""Deterministic stdio LSP subprocess used by Zig integration tests."""
import json
import os
import re
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

def offset_at(source, position):
    # Python splitlines also splits Unicode separators, which LSP does not.
    lines = re.findall(r"[^\r\n]*(?:\r\n|\r|\n|$)", source)
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or source.endswith(("\n", "\r")):
        lines.append("")
    line = position["line"]
    assert 0 <= line < len(lines), position
    content = lines[line].rstrip("\r\n")
    prefix = "".join(lines[:line])
    units = 0
    for index, character in enumerate(content):
        if units == position["character"]:
            return len(prefix) + index
        units += len(character.encode("utf-16-le")) // 2
    assert units == position["character"], position
    return len(prefix) + len(content)

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
        assert params["capabilities"]["general"]["positionEncodings"] == ["utf-16"]
        capabilities = {"positionEncoding": "utf-16", "completionProvider": {}, "hoverProvider": True, "definitionProvider": True, "referencesProvider": True, "renameProvider": True, "documentFormattingProvider": True}
        if mode != "sync-omitted":
            capabilities["textDocumentSync"] = (
                {"openClose": True, "change": 2} if mode == "incremental-object"
                else {"openClose": True, "change": 0} if mode == "sync-none-open"
                else 0 if mode == "sync-none"
                else 2 if mode == "incremental" else 1
            )
        if mode == "unsupported-encoding":
            capabilities["positionEncoding"] = "utf-8"
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": capabilities}})
    elif method == "initialized":
        assert isinstance(message.get("params"), dict), "initialized params must be a JSON object"
        initialized = True
        send({"jsonrpc": "2.0", "id": "configuration-1", "method": "workspace/configuration", "params": {"items": [{"section": "fixture"}]}})
        send({"jsonrpc": "2.0", "id": "progress-1", "method": "window/workDoneProgress/create", "params": {"token": "fixture-progress"}})
        send({"jsonrpc": "2.0", "id": "server-1", "method": "workspace/unsupported", "params": {}})
    elif method == "textDocument/didOpen":
        assert initialized
        assert mode not in ("sync-none", "sync-omitted")
        document = params["textDocument"]
        opened[document["uri"]] = document
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document["uri"], "version": document["version"], "diagnostics": [{"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}}, "severity": 2, "message": "emoji warning", "source": "fixture"}]}})
    elif method == "textDocument/didChange":
        document = params["textDocument"]
        old = opened[document["uri"]]
        assert document["version"] > old["version"]
        assert mode not in ("sync-none", "sync-none-open", "sync-omitted")
        old.update(document)
        for change in params["contentChanges"]:
            if mode in ("incremental", "incremental-object"):
                assert "range" in change
                start = offset_at(old["text"], change["range"]["start"])
                end = offset_at(old["text"], change["range"]["end"])
                assert start <= end
                old["text"] = old["text"][:start] + change["text"] + old["text"][end:]
            else:
                assert "range" not in change
                old["text"] = change["text"]
        if mode in ("incremental", "incremental-object", "verify-full"):
            send({"jsonrpc": "2.0", "method": "window/logMessage", "params": {"type": 3, "message": "sync:" + json.dumps({"version": old["version"], "text": old["text"], "changes": len(params["contentChanges"])}, ensure_ascii=False)}})
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": document["uri"], "version": document["version"], "diagnostics": []}})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"contents": {"kind": "markdown", "value": "```zig\nfn answer() u32\n```\nReturns the answer."}}})
    elif method == "textDocument/definition":
        send({"jsonrpc": "2.0", "id": message["id"], "result": [{"uri": params["textDocument"]["uri"], "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}]})
    elif method == "textDocument/references":
        send({"jsonrpc": "2.0", "id": message["id"], "result": [{"uri": params["textDocument"]["uri"], "range": {"start": {"line": 0, "character": 2}, "end": {"line": 0, "character": 3}}}]})
    elif method == "textDocument/rename":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"changes": {params["textDocument"]["uri"]: [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "newText": params["newName"]}]}}})
    elif method == "textDocument/formatting":
        send({"jsonrpc": "2.0", "id": message["id"], "result": [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "newText": "F"}]})
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
