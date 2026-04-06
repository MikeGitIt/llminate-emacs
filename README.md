# llminate-emacs

Emacs integration for the [llminate](https://github.com/MikeGitIt/llminate) AI coding assistant, with an extensible backend system supporting multiple AI coding agents.

## Features

- **Multi-backend support** -- llminate, Claude Code, Gemini CLI, Codex CLI, and Aider out of the box, with a registration API for adding more
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
  - **Gemini CLI** -- install via `npm install -g @anthropic-ai/gemini-cli` (or see [gemini-cli](https://github.com/google-gemini/gemini-cli))
  - **Codex CLI** -- install via `cargo install codex` (or see [codex](https://github.com/openai/codex))
  - **Aider** -- install via `pip install aider-chat` (or see [aider](https://aider.chat))
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

**IMPORTANT:** You must `(require 'llminate)`, NOT `(require 'llminate-mode)`. The `llminate.el` entry point loads all backend adapters. Loading `llminate-mode` directly skips the adapters and only the llminate backend will be available. See [Troubleshooting: Only one backend appears](#only-one-backend-appears-in-switch-backend).

## Configuration

### Choosing a backend

The `llminate-bridge-backend` variable controls which AI backend to use. Set it before enabling `llminate-mode`, or switch at runtime with `C-c q b`.

```elisp
;; Use the llminate Rust binary (default)
(setq llminate-bridge-backend 'llminate)

;; Use Claude Code CLI
(setq llminate-bridge-backend 'claude-code)

;; Use Gemini CLI
(setq llminate-bridge-backend 'gemini-cli)

;; Use Codex CLI (OpenAI)
(setq llminate-bridge-backend 'codex-cli)

;; Use Aider
(setq llminate-bridge-backend 'aider)
```

### Backend executables

```elisp
;; Path to the llminate binary (default: "llminate")
(setq llminate-bridge-executable "llminate")

;; Path to the Claude Code CLI (default: "claude")
(setq llminate-bridge-claude-executable "claude")

;; Path to the Gemini CLI (default: "gemini")
(setq llminate-bridge-gemini-executable "gemini")

;; Path to the Codex CLI (default: "codex")
(setq llminate-bridge-codex-executable "codex")

;; Path to Aider (default: "aider")
(setq llminate-bridge-aider-executable "aider")
```

### Aider-specific settings

```elisp
;; Allow Aider to auto-commit changes (default: nil)
(setq llminate-bridge-aider-auto-commit nil)

;; Extra files to include in Aider's context
(setq llminate-bridge-aider-extra-files '("src/main.rs" "Cargo.toml"))
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
| `C-c q b` | `llminate-bridge-switch-backend` | Switch between registered backends       |

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

Use `C-c q b` or `M-x llminate-bridge-switch-backend` to switch between any registered backend without restarting Emacs. If a session is running, it will be stopped and restarted with the new backend. The completion menu shows all registered backends with their labels.

To persist your choice across sessions, set `llminate-bridge-backend` in your init file.

### Backend comparison

| Feature              | llminate              | Claude Code           | Gemini CLI            | Codex CLI             | Aider                 |
|----------------------|-----------------------|-----------------------|-----------------------|-----------------------|-----------------------|
| Process model        | Long-lived subprocess | One process per turn  | One process per turn  | One process per turn  | One process per turn  |
| Multi-turn           | Continuous stdin      | `--resume SESSION_ID` | `--resume SESSION_ID` | `--thread-id ID`      | None (independent)    |
| Protocol             | JSON-lines            | NDJSON (stream-json)  | NDJSON (stream-json)  | NDJSON (exec --json)  | Plain text            |
| Text streaming       | Yes (chunks)          | Yes (deltas)          | Yes (deltas)          | No (all at once)      | No (all at once)      |
| Tool events          | ToolUse/ToolResult    | content_block_*       | tool_use/tool_result  | item.started/completed| Regex-detected edits  |
| Tool approval        | Full approval UI      | Not available         | Not available         | Not available         | Auto-approved (--yes) |
| Emacs command exec   | EmacsEval via stdio   | emacsclient via Bash  | emacsclient via Bash  | emacsclient via Bash  | emacsclient via Bash  |
| Modeline prefix      | `llm`                 | `cc`                  | `gm`                  | `cx`                  | `ai`                  |

When using external CLI backends (Claude Code, Gemini, Codex, Aider):
- The tool approval module is dormant (tools execute autonomously inside the CLI)
- Emacs commands work via `emacsclient -e` instead of the stdio pipe -- same whitelist, same security levels
- The Emacs server is auto-started when backends with a `:setup-fn` are activated (e.g., Claude Code)
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
| `llminate-bridge.el`          | Process bridge, backend registry, and dispatch  |
| `llminate-bridge-claude.el`   | Claude Code CLI adapter (NDJSON stream-json)    |
| `llminate-bridge-gemini.el`   | Gemini CLI adapter (NDJSON stream-json)         |
| `llminate-bridge-codex.el`    | Codex CLI adapter (NDJSON exec --json)          |
| `llminate-bridge-aider.el`    | Aider adapter (plain text, regex-based parsing) |
| `llminate-chat.el`            | Streaming chat UI with markdown rendering       |
| `llminate-layout.el`          | IDE multi-panel layout and activity log         |
| `llminate-approval.el`        | Tool approval UX with ediff and transient       |
| `llminate-emacs-commands.el`  | Emacs command whitelist and execution layer     |
| `llminate-session.el`         | Session persistence, resume, chat log export    |
| `llminate-completion.el`      | Copilot-style ghost text inline completion      |
| `llminate-pkg.el`             | Package metadata                                |

## Prompt history

The `*llminate Prompt*` buffer supports history navigation:

| Key        | Action                                              |
|------------|-----------------------------------------------------|
| `Up`       | Previous prompt (when cursor is on the first line)  |
| `Down`     | Next prompt (when cursor is on the last line)       |
| `M-p`      | Previous prompt (from anywhere)                     |
| `M-n`      | Next prompt (from anywhere)                         |
| `C-c C-c`  | Send the prompt                                     |
| `C-c C-k`  | Clear the prompt                                    |

History is kept in memory for the current session (up to `llminate-chat-max-history` entries, default 100).

## Smart selection

Place your cursor inside any code and use these to auto-select the enclosing code unit (function, struct, block, etc.) and send it to the AI:

| Key       | Command                  | Description                         |
|-----------|--------------------------|-------------------------------------|
| `C-c q E` | `llminate-smart-explain` | Select enclosing code + explain     |
| `C-c q F` | `llminate-smart-fix`     | Select enclosing code + fix/improve |

Selection uses tree-sitter when available (Emacs 29.1+), falling back to `beginning-of-defun`/`end-of-defun`. If a region is already active, it uses the existing selection. The selected region is briefly highlighted with `pulse` before sending.

The lowercase variants (`C-c q e`, `C-c q f`) still require a manually selected region.

## Troubleshooting

### Only one backend appears in switch-backend

**Cause:** Your init file loads `(require 'llminate-mode)` instead of `(require 'llminate)`. The `llminate-mode.el` module only loads the core bridge (which registers the `llminate` backend). The adapter files for Claude Code, Gemini, Codex, and Aider are loaded by `llminate.el` — if you skip it, those backends never register.

**Fix:**

1. Change your init file to use the correct entry point:

   ```elisp
   ;; WRONG — only the llminate backend will be available
   (require 'llminate-mode)

   ;; CORRECT — loads all backend adapters
   (require 'llminate)
   ```

2. If you installed via the symlink method, make sure **all** adapter `.el` files are symlinked into your load path:

   ```bash
   # Re-run the symlink loop to pick up any new files
   for f in ~/Code/llminate-emacs/*.el; do
     ln -sf "$f" ~/.emacs.d/lisp/$(basename "$f")
   done
   ```

3. Restart Emacs and verify that all backends are registered:

   ```
   M-: (mapcar #'car llminate-bridge--backend-registry)
   ```

   Should return `(aider codex-cli gemini-cli claude-code llminate)` (order may vary).

### Claude Code: "Emacs commands are being denied"

**Cause:** Claude Code's own permission system blocks `emacsclient` calls from its Bash tool. In `--print` mode (`-p`), it cannot prompt for approval interactively, so it silently denies unrecognized commands.

**Fix:** This is handled automatically -- `llminate-bridge-claude.el` passes `--allowedTools "Bash(*emacsclient*)"` when spawning the Claude Code process. If you still see denials:

1. Verify the bridge file is loaded: `M-: (featurep 'llminate-bridge-claude)`
2. Restart the bridge: `M-x llminate-bridge-restart`
3. Check that `llminate-bridge-claude--build-args` includes the `--allowedTools` flag: `M-: (llminate-bridge-claude--build-args)`

### Claude Code: no response in chat buffer

**Cause:** Claude Code with `-p --output-format stream-json` requires `--verbose`, and the response arrives in a single `assistant` event (not incremental `content_block_delta` events).

**Fix:** Both are handled automatically. If you see no output:

1. Enable debug output: `(setq llminate-bridge-debug-process-output t)`
2. Send a prompt, then check ` *claude-code-process*` (note the leading space) for raw NDJSON
3. Check `*Messages*` for JSON parse errors or unhandled event types

### emacsclient: "can't find socket" or connection refused

**Cause:** The Emacs server isn't running, or `emacsclient` can't find the socket.

**Fix:**

1. Verify the server is running: `M-x server-running-p` (should return `t`)
2. If not, start it: `M-x server-start`
3. `llminate-mode` auto-starts the server when the Claude Code backend is active, but if you enabled the mode before switching backends, restart it: `M-x llminate-mode` twice (off then on)

### emacsclient works from terminal but not from Claude Code

**Cause:** Claude Code's Bash tool runs in a sandboxed environment. The `--allowedTools` flag (see above) must whitelist `emacsclient`. Additionally, interactive commands that open buffers (e.g., `magit-diff-buffer-file`) require the Emacs frame to be raised so the display is visible.

**Verify from terminal:**

```bash
emacsclient -s server -e '(llminate-emacs-commands-cli-dispatch "buffer-name")' 2>&1; echo "EXIT: $?"
```

Should return `{"success":true,"result":"..."}` with exit code 0.

### Commands execute but nothing appears in Emacs

**Cause:** When `emacsclient -e` is called from an external process, Emacs may not raise its frame, so visual commands (magit-diff, find-file) execute but their buffers aren't visible.

**Fix:** The dispatch layer calls `select-frame-set-input-focus` after execution to raise the Emacs frame. If buffers still don't appear, check that `llminate-emacs-commands--user-window` is selecting the right window (it skips treemacs, llminate panels, and dedicated side windows).

### Wrong buffer targeted by Emacs commands

**Cause:** The `--user-window` function picks the most appropriate code window, skipping treemacs, llminate buffers, and dedicated side windows. If the wrong window is selected, file-specific commands (like `magit-diff-buffer-file`) may target the wrong buffer.

**Fix:** For file-specific magit commands, the AI should first call `find-file` to open the target file, then call the magit command with no arguments (it operates on the current buffer). The instructions injected into Claude Code prompts explain this pattern.

### Byte-compilation warnings

If you byte-compile the package and see warnings about undefined functions (`flymake-diagnostics`, `server-running-p`, `treesit-*`), these are expected -- the functions are declared with `declare-function` and are guarded at runtime by availability checks.

## Debugging

Enable raw process output logging:

```elisp
(setq llminate-bridge-debug-process-output t)
```

Then inspect the process buffer:
- `*llminate-process*` for the llminate backend
- ` *claude-code-process*` for the Claude Code backend (note leading space)
- ` *gemini-cli-process*` for the Gemini CLI backend (note leading space)
- ` *codex-cli-process*` for the Codex CLI backend (note leading space)
- ` *aider-process*` for the Aider backend (note leading space)

Check `*Messages*` for:
- `[llminate]` or `[claude-code]` prefixed messages from the bridge
- Unhandled event types (when debug is enabled)
- JSON parse errors from malformed stream data

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
