import json,sys
protocol=sys.argv[1]
settings={"model":"fixture-model","mode":"build","effort":"low"}
def config_options():
    return [{"id":"model","category":"model","type":"select","currentValue":settings["model"],"options":[{"value":"fixture-model","name":"Fixture"},{"value":"fixture-other","name":"Other model"}]},{"id":"mode","category":"mode","type":"select","currentValue":settings["mode"],"options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]},{"id":"effort","category":"thought_level","type":"select","currentValue":settings["effort"],"options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}]
def send(value):
    data=json.dumps(value,ensure_ascii=False)+"\n"
    for part in [data[:7],data[7:]]:
        sys.stdout.write(part);sys.stdout.flush()
def result(id,data):send({"jsonrpc":"2.0","id":id,"result":data})
for line in sys.stdin:
    m=json.loads(line);method=m.get("method");p=m.get("params",{});id=m.get("id")
    if method=="initialize":
        if protocol=="acp":
            assert p["protocolVersion"]==1
            result(id,{"protocolVersion":1,"agentCapabilities":{"loadSession":True}})
        else:result(id,{"userAgent":"fixture"})
    elif method=="session/new":
        assert p["mcpServers"]==[]
        result(id,{"sessionId":"fixture-session","models":{"currentModelId":"fixture-model","availableModels":[{"modelId":"fixture-model","name":"Fixture"}]},"configOptions":config_options()})
    elif method=="session/load":result(id,{"configOptions":config_options()})
    elif method in ("thread/start","thread/resume"):
        assert p["approvalPolicy"]=="on-request" and p["sandbox"]=="workspace-write"
        result(id,{"thread":{"id":"fixture-session"}})
    elif method=="model/list":result(id,{"data":[{"id":"fixture-model","displayName":"Fixture"}]})
    elif method in ("session/prompt","turn/start"):
        prompt_id=id
        if protocol=="acp":
            send({"method":"session/update","params":{"sessionId":"fixture-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello 日🙂"}}}})
            send({"id":"permit-1","method":"session/request_permission","params":{"sessionId":"fixture-session","toolCall":{"title":"Edit example.txt"},"options":[{"optionId":"allow","name":"Allow once","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}})
        else:
            result(id,{"turn":{"id":"turn-1"}})
            send({"method":"item/agentMessage/delta","params":{"delta":"Hello 日🙂"}})
            send({"id":99,"method":"item/fileChange/requestApproval","params":{"reason":"Edit example.txt"}})
    elif method=="session/set_config_option":
        settings[p["configId"]]=p["value"]
        result(id,{"configOptions":config_options()})
    elif method=="session/set_model":result(id,{})
    elif method in ("session/cancel","turn/interrupt"):
        if protocol=="acp":result(prompt_id,{"stopReason":"cancelled"})
        else:result(id,{});send({"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"interrupted"}}})
    elif method is None and "result" in m:
        allowed=m["result"]["outcome"].get("optionId")=="allow" if protocol=="acp" else m["result"]["decision"]=="accept"
        if allowed:
            with open("example.txt","w") as f:f.write("approved edit\n")
        if protocol=="acp":result(prompt_id,{"stopReason":"end_turn"})
        else:send({"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}})
