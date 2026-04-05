# llminate-emacs

Emacs integration for the [llminate](https://github.com/mickillah/llminate) AI coding assistant, with support for Claude Code CLI as an alternative backend.

## Features

- **Dual backend support** -- use either the llminate Rust binary or Claude Code CLI (`claude -p`)
- **Streaming chat UI** with markdown rendering in a dedicated side panel
- **IDE-style multi-panel layout** -- treemacs, editor, chat log, activity log, and prompt input
- **Tool approval interface** with ediff preview for file edits, syntax-highlighted Bash commands, and transient menus
- **Whitelisted Emacs command execution** -- the AI can call Emacs functions (find-file, magit, eglot, etc.) with a security whitelist
- **Session persistence and resume** -- save/resume conversations across Emacs restarts, auto-export to Markdown/HTML/Org
- **Copilot-style ghost text completion** -- inline AI suggestions with Tab to accept

## Requirements

- Emacs 29.1 or later
- [transient](https://github.com/magit/transient) 0.4+ (ships with recent Emacs)
- At least one backend:
  - **llminate** -- the Rust binary (`cargo install llminate` or build from source)
  - **Claude Code CLI** -- install via `npm install -g @anthropic-ai/claude-code`
- Optional: [pandoc](https://pandoc.org/) for HTML/Org chat log export
- Optional: [treemacs](https://github.com/Alexander-Miller/treemacs) for the file tree panel in the IDE layout

## Installation

### From source (symlink method)

Clone the repository and symlink the `.el` files into your load path:

```bash
git clone https://github.com/mickillah/llminate-emacs.git ~/Code/llminate-emacs

# Symlink all .el files into your Emacs load path
for f in ~/Code/llminate-emacs/*.el; do
  ln -sf "$f" ~/.emacs.d/lisp/$(basename "$f")
done
```

Make sure `~/.emacs.d/lisp/` is in your `load-path`:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
```

### Activation

Add to your init file:

```elisp
(require 'llminate)
(llminate-mode 1)
```

## Configuration

### Choosing a backend

The `llminate-bridge-backend` variable controls which AI backend to use. Set it before enabling `llminate-mode`, or switch at runtime with `C-c q b`.

```elisp
;; Use the llminate Rust binary (default)
(setq llminate-bridge-backend 'llminate)

;; Use Claude Code CLI instead
(setq llminate-bridge-backend 'claude-code)
```

### Backend executables

```elisp
;; Path to the llminate binary (default: "llminate")
(setq llminate-bridge-executable "llminate")

;; Path to the Claude Code CLI (default: "claude")
(setq llminate-bridge-claude-executable "claude")
```

### Model selection

```elisp
;; Use a specific model (nil = backend default)
(setq llminate-bridge-model "claude-sonnet-4-5-20250929")
```

### Permission mode

Controls how tool execution is authorized:

```elisp
;; "ask" = prompt for approval (default)
;; "allow" = auto-approve everything
;; "deny" = deny all tool execution
(setq llminate-bridge-permission-mode "ask")
```

When using the Claude Code backend, these map to Claude Code's permission modes: `"ask"` becomes `"default"`, `"allow"` becomes `"bypassPermissions"`, `"deny"` becomes `"plan"`.

### Extra CLI arguments

```elisp
;; Pass additional arguments to the backend process
(setq llminate-bridge-extra-args '("--verbose"))
```

### Session settings

```elisp
;; Where sessions are persisted (default: ~/.emacs.d/llminate-sessions.json)
(setq llminate-session-file "~/.emacs.d/llminate-sessions.json")

;; Auto-save session on Emacs exit (default: t)
(setq llminate-session-auto-save t)

;; Auto-resume last session for the current project on start (default: nil)
(setq llminate-session-auto-resume t)

;; Auto-export chat logs after each turn (default: t)
;; Exports to .claude/conversations/ as .md, .html, .org
(setq llminate-session-chatlog-auto-save t)

;; Path to pandoc for HTML/Org export (default: "pandoc")
(setq llminate-session-pandoc-executable "pandoc")
```

### Layout settings

```elisp
;; Chat panel width as a fraction of the frame (default: 0.35)
(setq llminate-layout-chat-width 0.35)

;; Activity log height in lines (default: 8)
(setq llminate-layout-activity-height 8)

;; Prompt input height in lines (default: 5)
(setq llminate-layout-prompt-height 5)
```

### Tool approval

```elisp
;; Tools that are always auto-approved (skip the approval prompt)
(setq llminate-approval-auto-allow-tools '("Read" "Glob" "Grep"))

;; Max lines shown in approval preview before truncating (default: 80)
(setq llminate-approval-preview-max-lines 80)
```

### Ghost text completion

```elisp
;; Completion server port (default: 3000)
(setq llminate-completion-server-port 3000)

;; Path to the completion server binary
(setq llminate-completion-server-binary
      (expand-file-name "~/path/to/ruemacs_completion_server"))

;; AI provider for completions: "openai" or "anthropic" (default: "openai")
(setq llminate-completion-provider "anthropic")

;; Idle delay before triggering a completion request (default: 0.5s)
(setq llminate-completion-debounce-delay 0.5)

;; Temperature and max tokens
(setq llminate-completion-temperature 0.2)
(setq llminate-completion-max-tokens 256)

;; Lines of surrounding context sent to the server (default: 50)
(setq llminate-completion-context-lines 50)
```

## Keybindings

All keybindings are under the `C-c q` prefix:

| Key       | Command                          | Description                              |
|-----------|----------------------------------|------------------------------------------|
| `C-c q q` | `llminate-chat-toggle`           | Toggle the chat panel                    |
| `C-c q s` | `llminate-chat-send`             | Send the current prompt                  |
| `C-c q l` | `llminate-layout-toggle`         | Toggle the IDE multi-panel layout        |
| `C-c q r` | `llminate-session-resume`        | Resume a saved session                   |
| `C-c q c` | `llminate-command-palette`       | Open the command palette                 |
| `C-c q e` | `llminate-explain-region`        | Send selected region for explanation     |
| `C-c q f` | `llminate-fix-region`            | Send selected region for fixing          |
| `C-c q d` | `llminate-send-diagnostics`      | Send flymake diagnostics to the AI       |
| `C-c q .` | `completion-at-point`            | Trigger completion-at-point              |
| `C-c q w` | `llminate-emacs-commands-list`   | List allowed Emacs commands              |
| `C-c q m` | `llminate-chat-set-render-backend` | Switch markdown render backend         |
| `C-c q b` | `llminate-bridge-switch-backend` | Switch between llminate / Claude Code    |

### Tool approval keys

When an approval prompt is displayed:

| Key | Action                                        |
|-----|-----------------------------------------------|
| `y` | Approve                                       |
| `n` | Deny                                          |
| `a` | Always allow this tool for the session        |
| `e` | Edit the command before approving (Bash only) |
| `d` | Show ediff comparison (file edits only)       |
| `q` | Quit (deny)                                   |

### Ghost text completion keys

When a ghost text suggestion is visible:

| Key   | Action                       |
|-------|------------------------------|
| `TAB` | Accept the full suggestion   |
| `M-f` | Accept the next word only    |
| `C-g` | Dismiss the suggestion       |

## Switching backends at runtime

Use `C-c q b` or `M-x llminate-bridge-switch-backend` to switch between the llminate and Claude Code backends without restarting Emacs. If a session is running, it will be stopped and restarted with the new backend.

To persist your choice across sessions, set `llminate-bridge-backend` in your init file.

### Backend differences

| Feature              | llminate                        | Claude Code CLI                  |
|----------------------|---------------------------------|----------------------------------|
| Process model        | Single long-lived subprocess    | One process per turn             |
| Multi-turn           | Continuous stdin                | `--resume SESSION_ID`            |
| Tool approval        | Full approval UI with ediff     | Not available (pre-configured)   |
| Emacs command exec   | EmacsEval over stdio pipe       | emacsclient -e via Bash          |
| Text streaming       | `Message` events with chunks    | `content_block_delta` events     |
| Modeline indicator   | `llm[idle]`, `llm[streaming]`   | `cc[idle]`, `cc[streaming]`      |

When using the Claude Code backend:
- The tool approval module is dormant (tools execute autonomously inside Claude Code)
- Emacs commands work via `emacsclient -e` instead of the stdio pipe -- same whitelist, same security levels
- The Emacs server is auto-started when you switch to the Claude Code backend
- Tool activity is still logged in the activity buffer with synthetic results

## Emacs command whitelist

Both backends can execute Emacs functions through the same whitelist-based security layer. The transport differs:
- **llminate backend**: EmacsEval events over the bidirectional stdio pipe
- **Claude Code backend**: `emacsclient -e` via Claude Code's Bash tool

Commands must be registered in the whitelist with a security level:

- **allow** -- execute immediately, return the result
- **prompt** -- show an approval dialog before executing
- **deny** -- never execute, return an error

### Default allowed commands

The whitelist includes commands for:

- **File/buffer operations**: `find-file`, `save-buffer`, `buffer-string`, `goto-line`, etc.
- **Magit (git)**: `magit-status`, `magit-stage-file`, `magit-commit` (prompt), `magit-push` (prompt), etc.
- **Eglot/LSP**: `eglot-rename` (prompt), `eglot-code-actions`, `xref-find-definitions`, `flymake-diagnostics`, etc.
- **Compilation**: `compile` (prompt), `recompile`, `next-error`, etc.
- **Project**: `project-root`, `project-files`, `project-find-file`, etc.
- **Window management**: `split-window-right`, `delete-window`, `balance-windows`, etc.
- **Read-only queries**: `point`, `line-number-at-pos`, `buffer-modified-p`, `default-directory`, etc.

### Managing the whitelist

```elisp
;; Add a command
(llminate-emacs-commands-add "my-custom-function" 'allow)

;; Remove a command
(llminate-emacs-commands-remove "my-custom-function")

;; Check a command's level
(llminate-emacs-commands-get-level "find-file")  ; => allow

;; List all commands: C-c q w or
(llminate-emacs-commands-list)
```

Commands execute in the user's code window, not the chat panel, so functions like `find-file` open files where you expect them.

### How Emacs commands work (architecture)

Both backends route through the same whitelist (`llminate-emacs-commands.el`) and execute in the user's code window. The transport differs:

#### llminate backend: bidirectional stdio pipe

The llminate binary runs as a subprocess of Emacs, started by `llminate-bridge.el` via `make-process`. Communication is bidirectional JSON-lines over stdin/stdout:

```
Emacs (parent process)
  |
  |-- stdout --> llminate reads: user prompts, EmacsEvalResult
  |
  +-- stdin  <-- llminate writes: Message, ToolUse, EmacsEval, etc.
```

The chain:

1. AI calls the `EmacsCommand` tool with `{"command": "find-file", "args": ["/path/to/file"]}`
2. Rust writes `{"type":"EmacsEval","command":"find-file","args":[...],"request_id":"abc"}` to stdout
3. Emacs process filter dispatches to `llminate-bridge--handle-emacs-eval`
4. `llminate-emacs-commands-execute` checks the whitelist, runs the function in the user's code window
5. Emacs writes `{"type":"EmacsEvalResult","request_id":"abc","success":true,"result":"..."}` back to stdin
6. Rust delivers the result to the waiting tool via a oneshot channel
7. AI receives the result and continues

No external processes, no server sockets, no `emacsclient`.

#### Claude Code backend: emacsclient

Claude Code is a separate binary with its own tool registry -- it doesn't know about our `EmacsCommand` tool. Instead, the AI calls Emacs functions through its Bash tool using `emacsclient -e`, which talks to Emacs via the standard `server-start` socket:

```
Claude Code CLI
  |
  +-- Bash tool --> emacsclient -e '(llminate-emacs-commands-cli-dispatch "find-file" "/path")'
                       |
                       +-- Emacs server socket --> llminate-emacs-commands-cli-dispatch
                                                     |
                                                     +-- whitelist check --> execute in user window
                                                     |
                                                     +-- JSON result string <-- stdout
```

The chain:

1. AI sees the emacsclient instructions in the prompt context (injected automatically)
2. AI uses its Bash tool to run `emacsclient -e '(llminate-emacs-commands-cli-dispatch "find-file" "/path")'`
3. `emacsclient` connects to the running Emacs server
4. `llminate-emacs-commands-cli-dispatch` checks the whitelist (same security levels as the llminate backend)
5. If allowed, the function runs in the user's code window via `with-selected-window`
6. The result is returned as a JSON string: `{"success": true, "result": ...}`
7. Claude Code reads it from the Bash output

The Emacs server is auto-started when you enable `llminate-mode` with the `claude-code` backend, or when you switch to it at runtime via `C-c q b`.

### Testing Emacs commands

#### With the llminate backend

**1. Build the latest llminate binary:**

```bash
cd /path/to/llminate
cargo build --release
```

**2. Activate the mode in Emacs:**

```elisp
(require 'llminate)
(setq llminate-bridge-backend 'llminate)
(llminate-mode 1)
```

**3. Open the IDE layout** (`C-c q l`) and send a prompt:

- *"Open the file README.md in my editor"* -- should call `find-file`
- *"Show me the git status using magit"* -- should call `magit-status`
- *"What line am I on in the current buffer?"* -- should call `line-number-at-pos`

**4. What you should see:**

- Modeline changes to `llm[emacs:find-fi]`
- Activity log shows `[HH:MM:SS] Emacs      find-file "/path/to/README.md"`
- The actual effect happens in your code window
- The AI reports the result in the chat

**5. Debugging:** Enable `(setq llminate-bridge-debug-process-output t)` and check `*llminate-process*` for `EmacsEval`/`EmacsEvalResult` JSON lines.

#### With the Claude Code backend

**1. Activate with Claude Code:**

```elisp
(require 'llminate)
(setq llminate-bridge-backend 'claude-code)
(llminate-mode 1)
```

The Emacs server starts automatically. You can verify with `M-x server-running-p`.

**2. Open the IDE layout** (`C-c q l`) and send a prompt:

- *"Open README.md in my Emacs editor"*
- *"Run magit-status to show the git status"*
- *"What's the current line number in my buffer?"*

**3. What you should see:**

- Claude Code uses its Bash tool to call `emacsclient -e '(llminate-emacs-commands-cli-dispatch ...)'`
- The command executes in your code window (files open, magit appears, etc.)
- The JSON result appears in Claude's Bash output
- Claude reports the result in the chat

**4. Testing from a terminal** (useful for verifying the dispatch works independently):

```bash
# Should open a file in Emacs
emacsclient -e '(llminate-emacs-commands-cli-dispatch "find-file" "/path/to/file")'

# Should return the current line number as JSON
emacsclient -e '(llminate-emacs-commands-cli-dispatch "line-number-at-pos")'

# Should be denied (not in whitelist)
emacsclient -e '(llminate-emacs-commands-cli-dispatch "eval" "(delete-file \"/etc/passwd\")")'
```

**5. Debugging:** Check `*Messages*` for errors. If `emacsclient` can't connect, verify the server is running with `M-x server-running-p`.

## IDE layout

Toggle with `C-c q l`. The layout arranges your frame into:

```
+----------+------------------+-----------+
| treemacs |  main editor     |  chat log |
| (left)   |                  |  (right)  |
+----------+--------+---------+-----------+
| activity log      | prompt input        |
+-------------------+---------------------+
```

- **Chat log** -- streaming AI responses with markdown rendering
- **Activity log** -- timestamped tool executions, Emacs command calls, errors, session events
- **Prompt input** -- type your messages here, send with `C-c q s`
- **Treemacs** -- file tree (if treemacs is installed)

The previous window configuration is saved to a register and restored when the layout is toggled off.

## Session management

### Saving and resuming

Sessions are auto-saved when Emacs exits (if `llminate-session-auto-save` is non-nil). You can also save manually:

- `M-x llminate-session-save` -- save the current session
- `M-x llminate-session-resume` (`C-c q r`) -- pick a session to resume
- `M-x llminate-session-list` -- browse sessions (RET to resume, d to delete, q to quit)

### Chat log export

After each turn, the conversation is exported to `.claude/conversations/` in three formats:
- **Markdown** (`.md`) -- always written
- **HTML** (`.html`) -- requires pandoc
- **Org** (`.org`) -- requires pandoc

Disable with `(setq llminate-session-chatlog-auto-save nil)`.

## Modeline

The modeline indicator shows the active backend and current state:

| Indicator            | Meaning                          |
|----------------------|----------------------------------|
| `llm[off]`           | Mode disabled                    |
| `llm[idle]`          | llminate backend, waiting        |
| `llm[streaming]`     | Receiving AI response            |
| `llm[tool:Bash]`     | Tool executing (shows tool name) |
| `llm[emacs:find-fi]` | Emacs command executing          |
| `llm[awaiting]`      | Waiting for user approval        |
| `cc[idle]`           | Claude Code backend, waiting     |
| `cc[streaming]`      | Claude Code streaming response   |
| `cc[tool:Read]`      | Claude Code executing a tool     |

## Module overview

| File                          | Purpose                                        |
|-------------------------------|------------------------------------------------|
| `llminate.el`                 | Package entry point, loads all modules          |
| `llminate-mode.el`            | Global minor mode, keybindings, modeline        |
| `llminate-bridge.el`          | Process bridge with backend dispatch            |
| `llminate-bridge-claude.el`   | Claude Code CLI protocol adapter                |
| `llminate-chat.el`            | Streaming chat UI with markdown rendering       |
| `llminate-layout.el`          | IDE multi-panel layout and activity log         |
| `llminate-approval.el`        | Tool approval UX with ediff and transient       |
| `llminate-emacs-commands.el`  | Emacs command whitelist and execution layer     |
| `llminate-session.el`         | Session persistence, resume, chat log export    |
| `llminate-completion.el`      | Copilot-style ghost text inline completion      |
| `llminate-pkg.el`             | Package metadata                                |

## Debugging

Enable raw process output logging:

```elisp
(setq llminate-bridge-debug-process-output t)
```

Then inspect the process buffer:
- `*llminate-process*` for the llminate backend
- ` *claude-code-process*` for the Claude Code backend (note leading space)

## License

See the [llminate](https://github.com/mickillah/llminate) project for license details.
