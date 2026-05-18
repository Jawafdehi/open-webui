#!/usr/bin/env python3
"""
Mock OpenWebUI API server for testing bootstrap-config.sh.
Listens on a free port, responds to the API endpoints the bootstrap script calls.
"""

import json
import sys
import os
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# In-memory state
state = {
    "models": {},
    "prompts": [],
    "groups": [],
    "knowledge": [],
    "files": {},
    "request_log": [],
}

def log_request(method, path, body, status, response):
    entry = {
        "method": method,
        "path": path,
        "body": body,
        "status": status,
        "response_snippet": str(response)[:200],
    }
    state["request_log"].append(entry)
    print(f"[MOCK] {method} {path} -> {status}")

class MockHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        body = json.dumps(data).encode()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 0:
            return self.rfile.read(length).decode()
        return ""

    def _is_valid_token(self, token):
        return token == "test-api-key"

    def _check_auth(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._send_json(401, {"detail": "Not authenticated"})
            return False
        token = auth.split(" ", 1)[1]
        if not self._is_valid_token(token):
            self._send_json(401, {"detail": "Invalid token"})
            return False
        return True

    def do_GET(self):
        if not self._check_auth():
            return
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        # GET /api/v1/models/model?id=...
        if path == "/api/v1/models/model":
            model_id = qs.get("id", [None])[0]
            if model_id and model_id in state["models"]:
                self._send_json(200, state["models"][model_id])
            else:
                self._send_json(404, {"detail": "Model not found"})
            return

        # GET /api/v1/prompts/
        if path == "/api/v1/prompts/" or path == "/api/v1/prompts":
            self._send_json(200, {"items": state["prompts"]})
            return

        # GET /api/v1/groups/
        if path == "/api/v1/groups/" or path == "/api/v1/groups":
            self._send_json(200, {"items": state["groups"]})
            return

        # GET /api/v1/knowledge/
        if path == "/api/v1/knowledge/" or path == "/api/v1/knowledge":
            self._send_json(200, {"items": state["knowledge"]})
            return

        # GET /api/v1/tools/id/{tool_id}
        if path.startswith("/api/v1/tools/id/"):
            self._send_json(404, {"detail": "Tool not found"})
            return

        # GET /api/v1/files/
        if path == "/api/v1/files/" or path == "/api/v1/files":
            file_id = qs.get("id", [None])[0]
            if file_id and file_id in state["files"]:
                self._send_json(200, state["files"][file_id])
            else:
                self._send_json(404, {"detail": "File not found"})
            return

        self._send_json(404, {"detail": f"GET {path} not implemented"})

    def _handle_model_create(self, body):
        model_id = body.get("id")
        if model_id in state["models"]:
            self._send_json(400, {"detail": "Model already exists"})
            return
        state["models"][model_id] = {
            "id": model_id,
            "name": body.get("name", ""),
            "base_model_id": body.get("base_model_id"),
            "params": body.get("params", {}),
            "meta": body.get("meta", {}),
            "access_grants": body.get("access_grants", []),
            "is_active": body.get("is_active", True),
            "user_id": "mock-user",
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
        }
        self._send_json(200, state["models"][model_id])

    def _handle_model_update(self, body):
        model_id = body.get("id")
        if model_id in state["models"]:
            acc = body.get("access_grants", [])
            state["models"][model_id]["access_grants"] = acc
            state["models"][model_id]["updated_at"] = int(time.time())
        self._send_json(200, state["models"].get(model_id, body))

    def _handle_prompt_create(self, body):
        command = body.get("command")
        if any(p.get("command") == command for p in state["prompts"]):
            self._send_json(400, {"detail": "COMMAND_TAKEN"})
            return
        prompt = {
            "id": f"prompt-{len(state['prompts'])}",
            "command": command,
            "name": body.get("name", ""),
            "content": body.get("content", ""),
            "tags": body.get("tags", []),
            "user_id": "mock-user",
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
        }
        state["prompts"].append(prompt)
        self._send_json(200, prompt)

    def _handle_group_create(self, body):
        name = body.get("name")
        if any(g.get("name") == name for g in state["groups"]):
            self._send_json(400, {"detail": "Group exists"})
            return
        group = {
            "id": f"group-{len(state['groups'])}",
            "name": name,
            "description": body.get("description", ""),
            "permissions": body.get("permissions", {}),
            "user_id": "mock-user",
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
        }
        state["groups"].append(group)
        self._send_json(200, group)

    def _handle_knowledge_create(self, body):
        name = body.get("name")
        if any(k.get("name") == name for k in state["knowledge"]):
            self._send_json(400, {"detail": "Knowledge exists"})
            return
        kb = {
            "id": f"kb-{len(state['knowledge'])}",
            "name": name,
            "description": body.get("description", ""),
            "user_id": "mock-user",
            "access_grants": [],
            "created_at": int(time.time()),
            "updated_at": int(time.time()),
        }
        state["knowledge"].append(kb)
        self._send_json(200, kb)

    def _handle_knowledge_file_add(self, body):
        file_id = body.get("file_id", "unknown")
        self._send_json(200, {"status": "added", "file_id": file_id})

    def do_POST(self):
        if not self._check_auth():
            return
        path = urlparse(self.path).path
        body_raw = self._read_body()
        try:
            body = json.loads(body_raw) if body_raw else {}
        except json.JSONDecodeError:
            body = {}

        handlers = {
            "/api/v1/models/create": self._handle_model_create,
            "/api/v1/models/model/update": self._handle_model_update,
            "/api/v1/prompts/create": self._handle_prompt_create,
            "/api/v1/groups/create": self._handle_group_create,
            "/api/v1/knowledge/create": self._handle_knowledge_create,
        }
        if path in handlers:
            handlers[path](body)
            return
        if "/knowledge/" in path and "/file/add" in path:
            self._handle_knowledge_file_add(body)
            return

        self._send_json(404, {"detail": f"POST {path} not implemented"})

    def log_message(self, format, *args):
        pass  # suppress default logging

def start_server(port=0):
    server = HTTPServer(("127.0.0.1", port), MockHandler)
    actual_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, actual_port, thread

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Mock OpenWebUI API server")
    parser.add_argument("--port", type=int, default=0, help="Port to listen on")
    parser.add_argument("--timeout", type=int, default=30, help="Seconds to run before exiting")
    args = parser.parse_args()

    server, port, thread = start_server(args.port)
    print(f"MOCK_SERVER_PORT={port}", flush=True)

    try:
        time.sleep(args.timeout)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        print(json.dumps(state["request_log"], indent=2), flush=True)
