# El Yayster

**The** Emacs. **The** Lisp. A wild little yes: give a local LLM the keys.

Most "LLM in Emacs" packages make Emacs a *mouth* that talks to a model: you type,
it replies into a buffer. El Yayster inverts that. It makes Emacs a *body* the
model inhabits — the agent perceives your live environment, and **acts on it**
through gated Emacs Lisp. Decide → call a tool → read the result → repeat, against
any OpenAI-compatible endpoint. Local Ollama is the happy path. No cloud required.

The name is the joke and the thesis. *El* is the definite article — *the* Yayster —
and it is also `el`, as in Emacs Lisp. The rest is the dare: a carefree, fun-loving
mindset, the kind that looks at `eval` and `M-x` and says *yes, seat the model
there too*. The agent drafts; you still commit.

One self-contained file: `yayster.el`. No ELPA packages — `cl-lib`, `json`,
`subr-x`, the `curl` binary, and a reachable model.

---

## Why it's different

- **Situated.** Every turn, the agent is told what buffers you have open, your current
  mode, and your working directory. It *knows it's in Emacs* and speaks from inside it.
- **It acts, gated.** Capabilities like `eval_elisp`, `write_buffer`, and `run_command`
  let the agent operate the editor — but every *mutating* action asks your permission
  first. **The agent drafts; you commit.**
- **Self-discovering.** `apropos` and `describe` let it explore Emacs's own
  self-documentation. Its toolset grows from the editor itself.
- **Local-first & model-portable.** Any OpenAI-compatible `/chat/completions`
  endpoint. Tested across local models (Qwen, GLM) with no code changes.
- **Non-blocking.** Requests run in a `curl` subprocess; Emacs stays responsive.
  Progress streams into a `*yayster*` buffer.
- **Observable.** The `*yayster*` header line shows the live model, context-window
  occupancy (auto-detected from Ollama's `/api/show`), and per-turn / session token
  counts.

## Install

1. Drop `yayster.el` somewhere on disk.
2. Add to your init:

   ```elisp
   (add-to-list 'load-path "/path/to/yayster.el")  ; the directory
   (require 'yayster)
   (yayster-awaken)

   ;; Optional: quick keys
   (global-set-key (kbd "C-c y") #'yayster-step)
   (global-set-key (kbd "C-c Y") #'yayster-use-host)
   ```

3. Point it at your model (defaults to `http://localhost:11434/v1/chat/completions`):

   ```elisp
   (setq yayster-endpoint "http://localhost:11434/v1/chat/completions"
         yayster-model    "qwen3:8b")
   ```

## Requirements

- Emacs 28.1+
- `curl` on your `PATH` (built into macOS; `apt install curl` on Linux)
- An OpenAI-compatible chat endpoint. Easiest is [Ollama](https://ollama.com):
  `ollama pull qwen3:8b` then it serves on `localhost:11434`.

## Use

- `M-x yayster-step` (or `C-c y`) — ask in plain English.
  Watch `*yayster*`; the answer also echoes in the minibuffer.
  Tools run in the buffer and directory that were current when you issued the turn.
- `M-x yayster-use-host` (or `C-c Y`) — switch between endpoints in `yayster-hosts`.
- `M-x yayster-abort` — kill a hung turn, unlink temp files, clear the busy flag.

## Optional: mode-line indicator

`yayster-mode-line.el` shows the current host, model, and a pulse while a turn
is in flight:

```
 ⌬ local qwen3:8b        (idle)
 ⌬ local qwen3:8b ◐      (a turn is running)
```

```elisp
(require 'yayster-mode-line)   ;; installs itself into mode-line-format
```

It refreshes via advice on turn start/finish, host switch, abort, and safety
re-arm — no polling. Remove it with `M-x yayster-mode-uninstall`.

Try:

- *"What buffers do I have open?"*  → read-only, instant
- *"Count the functions matching org-agenda."*  → the agent discovers + calls `apropos`
- *"Give me a directory listing of my home dir, 5 most recent."*  → `run_command`
  (you'll be asked to approve it)

## Capabilities

| Capability | Mutating? | What it does |
|---|---|---|
| `read_buffer`  | no  | Read a buffer's text |
| `list_buffers` | no  | List buffers + major modes |
| `apropos`      | no  | Find functions matching a pattern (self-discovery) |
| `describe`     | no  | Read a function's docstring |
| `eval_elisp`   | **yes** | Evaluate an Emacs Lisp expression |
| `write_buffer` | **yes** | Replace a buffer's contents |
| `run_command`  | **yes** | Run a shell command |

Read-only capabilities auto-approve (`yayster-auto-approve-readonly`, default on).
**Mutating capabilities always prompt** via `yayster-confirm-function`. The
prompt includes the capability name and the **full** argument payload — the
command or elisp that will run, no truncation — so a rebind to `y-or-n-p` is
not blind. The same text is shown in `*yayster-permission*`. On a graphical
frame: **Allow**, **YOLO** (stop asking for the rest of the session; re-arm with
`M-x yayster-safety-on`), and **Deny**. On a terminal: `[y]/[n]/[!]`. C-g /
cancel is deny.
`run_command` times out after `yayster-command-timeout` seconds (default 30) and
caps output at `yayster-command-max-bytes`.

The ReAct protocol: `ACTION:` / `ARGS:` must start their own lines; a `FINAL:` line
ends the turn and is never executed, even if an ACTION pair is also quoted. Malformed
JSON ARGS is not a tool call.

## ⚠️ Safety

Mutating tools (`eval_elisp`, `write_buffer`, `run_command`) **always prompt**
(Allow / Deny). The prompt shows the full command or elisp — no truncation.
Default install is that gate — read the payload before you Allow.

**YOLO** is opt-in and **session-scoped** until `M-x yayster-safety-on`. It is not
the default. Demo the package with prompts on.

Read-only tools (`read_buffer`, `list_buffers`) auto-approve and can still send
**any open buffer** (including secrets) to the model. That is the point, and also
the footgun. The gate only protects you if you read what you approve.

If you set `yayster-api-key` for a hosted API, the bearer token is written to
a mode-0600 temp file and passed to curl as `-H @FILE`. It never appears on `ps`.

## How it works

Five small pieces, all in one file:

1. **Capabilities** — a registry of gated Elisp functions (the agent's hands).
2. **Permission gate** — read-only vs. mutating; mutating always asks.
3. **Situating prompt** — live environment + a tool manifest.
4. **Agent loop** — ReAct (`ACTION:` / `ARGS:` / `FINAL:`) against your endpoint.
5. **`awaken`** — seats El Yayster at startup.

It's a v0 and deliberately small — easy to read end to end, easy to extend.

## Tests

```bash
emacs -Q --batch -L . -l yayster.el -l test/yayster-tests.el \
  -f ert-run-tests-batch-and-exit
```

## Roadmap

- Native tool/function-calling (JSON-Schema `tools`) as an alternative to the ReAct text protocol
- Token-level streaming into `*yayster*`
- Automatic host failover
- org-roam–backed memory (remember / recall as a knowledge graph)

## License

MIT — see [LICENSE](LICENSE).
