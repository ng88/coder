# Coder Remote Agent

`coder` connects a local project to a ChatGPT custom GPT through a small bridge server. The agent runs on your machine, while the GPT calls tools and routes requests to the connected agent using the temporary token printed at startup.

## Quick test

The fastest way to try Coder is to use the default public server. You only need Python 3 and the `websockets` package.

Install the Python dependency:

```sh
python3 -m pip install websockets
```

### Linux / macOS

Run without installing:

```sh
curl -fsSL https://coder.nghs.fr/run.sh | sh
```

Or install the `coder` command:

```sh
curl -fsSL https://coder.nghs.fr/install.sh | sh
coder
```

### Windows PowerShell

Run without installing:

```powershell
irm https://coder.nghs.fr/run.ps1 | iex
```

Or install the `coder` command:

```powershell
irm https://coder.nghs.fr/install.ps1 | iex
coder
```

The agent connects to the default server automatically:

```text
wss://coder.nghs.fr/ws/agent
```

When it starts, it prints a temporary token in the form:

```text
machineid:authid
```

Keep the agent running, then create your own GPT in ChatGPT and configure it to use the Coder Action.

1. Create a new GPT in ChatGPT.
2. Copy the contents of [`instructions.md`](instructions.md) into the GPT's **Instructions** field.
3. Add an **Action** and import the OpenAPI schema from:

   ```text
   https://coder.nghs.fr/openapi.json
   ```

4. Save the GPT and start a conversation with it.
5. Start the conversation by giving it both the token and the task, for example:

   ```text
   My token is machineid:authid, can you implement yyy?
   ```

The GPT can then use the Action to work with the project from which you launched the agent.

### Platform notes

Linux uses Bubblewrap (`bwrap`) for sandboxed command execution. macOS uses `sandbox-exec`. Network access from commands inside the sandbox is disabled by default; start the agent with `--network` when sandboxed commands need outbound network access. Windows command execution currently runs without a sandbox, and the Windows launchers display a warning before starting the agent.

For example:

```sh
coder --network
```

`--network` only changes the sandbox policy. It has no effect together with `--no-sandbox`, because unsandboxed commands already have the host's normal network access.

## Deploy your own

You can run your own `server.py` instance and point both your agents and your own GPT at it.

### 1. Deploy the server

The server requires Python 3, FastAPI, and Uvicorn:

```sh
python3 -m pip install fastapi uvicorn
```

To start it run:

```sh
python3 server.py
```

Set `REMOTE_AGENT_API_URL` to the public HTTPS base URL of your server. This is
the URL advertised in the generated OpenAPI schema (`/openapi.json`).

Linux/macOS:

```sh
export REMOTE_AGENT_API_URL=https://coder.example.com
python3 server.py
```

Windows PowerShell:

```powershell
$env:REMOTE_AGENT_API_URL = 'https://coder.example.com'
python server.py
```

If `REMOTE_AGENT_API_URL` is not set, it defaults to `https://coder.nghs.fr`.

If your public server is available at:

```text
https://coder.example.com
```

then agents should connect to:

```text
wss://coder.example.com/ws/agent
```

and the GPT Actions/OpenAPI schema is available at:

```text
https://coder.example.com/openapi.json
```

### 2. Point the agent at your server

There are three ways to select another server.

#### Command-line parameter

```sh
coder --server wss://coder.example.com/ws/agent
```

#### Environment variable

The agent reads `REMOTE_AGENT_SERVER` when `--server` is not supplied.

For a self-hosted setup, configure both sides consistently:

```sh
export REMOTE_AGENT_API_URL=https://coder.example.com
export REMOTE_AGENT_SERVER=wss://coder.example.com/ws/agent
```

Linux/macOS:

```sh
export REMOTE_AGENT_SERVER=wss://coder.example.com/ws/agent
coder
```

Windows PowerShell:

```powershell
$env:REMOTE_AGENT_SERVER = 'wss://coder.example.com/ws/agent'
coder
```

#### Change the built-in default

If you maintain your own distribution, you can change this line in `agent.py`:

```python
DEFAULT_SERVER = os.environ.get("REMOTE_AGENT_SERVER", "wss://coder.nghs.fr/ws/agent")
```

After changing `agent.py`, regenerate all launchers:

```sh
./gen_install.sh
```

`gen_install.sh` is the only place that generates embedded copies of `agent.py`. It produces:

- `install.sh` — install on Linux/macOS
- `run.sh` — run without installing on Linux/macOS
- `install.ps1` — install on Windows
- `run.ps1` — run without installing on Windows

Do not edit the embedded agent inside those generated files directly.

### 3. Configure your GPT in ChatGPT

Create a GPT in ChatGPT, copy the contents of [`instructions.md`](instructions.md) into its **Instructions** field, then add an Action using your server's OpenAPI schema:

```text
https://coder.example.com/openapi.json
```

### Server configuration

`server.py` supports these command-line options:

```text
--host HOST
--port PORT
--log-level {critical,error,warning,info,debug}
--ssl-certfile FILE
--ssl-keyfile FILE
```

The log level can also be set with:

```sh
export REMOTE_AGENT_LOG_LEVEL=debug
```

Direct TLS is supported with `--ssl-certfile` and `--ssl-keyfile`, although terminating TLS at a reverse proxy is usually simpler for production deployments.

## Security

The agent can execute commands and modify files inside the project from which it is launched. The temporary token grants access to that connected agent for as long as the session remains valid, so treat it as a secret.

Prefer sandboxed execution where the platform supports it. Linux requires Bubblewrap and macOS uses `sandbox-exec`. Sandboxed commands do not get network access by default; use `--network` only when the work actually requires it. Windows command sandboxing is not implemented yet, so Windows currently runs commands with `--no-sandbox`; in that mode `--network` is unnecessary and has no effect.
