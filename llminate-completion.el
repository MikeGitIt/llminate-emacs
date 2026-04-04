;;; llminate-completion.el --- Copilot-style ghost text completion  -*- lexical-binding: t; -*-

;; Author: llminate
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: ai completion tools

;;; Commentary:

;; Provides GitHub Copilot-style inline ghost text completions.
;; Shows AI suggestions as dimmed overlay text after the cursor.
;; Tab accepts the suggestion; any other input dismisses it.
;;
;; Uses ruemacs_completion_server as the backend.

;;; Code:

(require 'json)
(require 'url)
(require 'cl-lib)

;; --- Customization ---

(defgroup llminate-completion nil
  "Copilot-style ghost text completion via ruemacs_completion_server."
  :group 'tools
  :prefix "llminate-completion-")

(defcustom llminate-completion-server-port 3000
  "Port the completion server listens on."
  :type 'integer
  :group 'llminate-completion)

(defcustom llminate-completion-server-binary
  (expand-file-name "~/ruemacs/src/ruemacs_completion_server/target/release/ruemacs_completion_server")
  "Path to the ruemacs_completion_server binary."
  :type 'file
  :group 'llminate-completion)

(defcustom llminate-completion-debounce-delay 0.5
  "Seconds of idle time before triggering an AI completion request."
  :type 'number
  :group 'llminate-completion)

(defcustom llminate-completion-provider "openai"
  "AI provider to use for completions (\"openai\" or \"anthropic\")."
  :type '(choice (const "openai") (const "anthropic"))
  :group 'llminate-completion)

(defcustom llminate-completion-temperature 0.2
  "Temperature for completion requests."
  :type 'number
  :group 'llminate-completion)

(defcustom llminate-completion-max-tokens 256
  "Maximum tokens for a single completion response."
  :type 'integer
  :group 'llminate-completion)

(defcustom llminate-completion-context-lines 50
  "Number of lines of surrounding context to send to the server."
  :type 'integer
  :group 'llminate-completion)

(defcustom llminate-completion-accept-key (kbd "TAB")
  "Key to accept the ghost text suggestion."
  :type 'key-sequence
  :group 'llminate-completion)

(defcustom llminate-completion-dismiss-key (kbd "C-g")
  "Key to explicitly dismiss the ghost text suggestion."
  :type 'key-sequence
  :group 'llminate-completion)

(defcustom llminate-completion-accept-word-key (kbd "M-f")
  "Key to accept only the next word of the ghost text suggestion."
  :type 'key-sequence
  :group 'llminate-completion)

;; --- Faces ---

(defface llminate-completion-ghost-face
  '((t :foreground "#6b7280" :slant italic))
  "Face for ghost text completion suggestions."
  :group 'llminate-completion)

;; --- Internal state ---

(defvar-local llminate-completion--overlay nil
  "Overlay showing the current ghost text suggestion.")

(defvar-local llminate-completion--suggestion nil
  "Current ghost text suggestion string, or nil.")

(defvar-local llminate-completion--suggestion-point nil
  "Buffer position where the current suggestion was generated.")

(defvar llminate-completion--server-process nil
  "Process handle for the managed completion server.")

(defvar llminate-completion--debounce-timer nil
  "Idle timer for debouncing completion requests.")

(defvar-local llminate-completion--last-tick 0
  "Buffer modification tick when last completion was fetched.")

(defvar-local llminate-completion--request-pending nil
  "Non-nil when an async completion request is in flight.")

(defvar llminate-completion--server-ready nil
  "Non-nil after the server health check succeeds.")

(defvar llminate-completion--health-check-pending nil
  "Non-nil while a health check request is in flight.")


;; --- Language ID mapping ---

(defvar llminate-completion--mode-language-alist
  '((rust-mode         . "rust")
    (rust-ts-mode      . "rust")
    (python-mode       . "python")
    (python-ts-mode    . "python")
    (js-mode           . "javascript")
    (js-ts-mode        . "javascript")
    (typescript-mode   . "typescript")
    (typescript-ts-mode . "typescript")
    (tsx-ts-mode       . "typescriptreact")
    (c-mode            . "c")
    (c-ts-mode         . "c")
    (c++-mode          . "cpp")
    (c++-ts-mode       . "cpp")
    (java-mode         . "java")
    (java-ts-mode      . "java")
    (go-mode           . "go")
    (go-ts-mode        . "go")
    (ruby-mode         . "ruby")
    (ruby-ts-mode      . "ruby")
    (emacs-lisp-mode   . "elisp")
    (lisp-mode         . "lisp")
    (sh-mode           . "shellscript")
    (bash-ts-mode      . "shellscript")
    (css-mode          . "css")
    (css-ts-mode       . "css")
    (html-mode         . "html")
    (html-ts-mode      . "html")
    (json-mode         . "json")
    (json-ts-mode      . "json")
    (yaml-mode         . "yaml")
    (yaml-ts-mode      . "yaml")
    (toml-ts-mode      . "toml")
    (sql-mode          . "sql")
    (lua-mode          . "lua")
    (zig-mode          . "zig"))
  "Alist mapping major modes to language identifiers.")

(defun llminate-completion--language-id ()
  "Return the language identifier for the current major mode."
  (or (alist-get major-mode llminate-completion--mode-language-alist)
      (let ((name (symbol-name major-mode)))
        (if (string-suffix-p "-mode" name)
            (string-remove-suffix "-mode"
                                  (string-remove-suffix "-ts" name))
          name))))

;; --- Server management ---

(defun llminate-completion--process-filter (proc output)
  "Process filter that watches for the server's listen message in OUTPUT.
Once \"SERVER IS LISTENING\" appears, sets `llminate-completion--server-ready'."
  ;; Append output to the process buffer
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert output)))
  ;; Check if the server announced it's listening
  (when (and (not llminate-completion--server-ready)
             (string-match-p "SERVER IS LISTENING" output))
    (setq llminate-completion--server-ready t)
    (message "llminate-completion: server is ready")))

(defun llminate-completion--process-sentinel (proc event)
  "Process sentinel that resets state when the server dies."
  (unless (process-live-p proc)
    (setq llminate-completion--server-ready nil)
    (setq llminate-completion--server-process nil)
    (message "llminate-completion: server exited — %s" (string-trim event))))

(defun llminate-completion-start-server ()
  "Start the ruemacs_completion_server as a subprocess."
  (interactive)
  (when (and llminate-completion--server-process
             (process-live-p llminate-completion--server-process))
    (message "llminate-completion: server already running")
    (cl-return-from llminate-completion-start-server))
  (unless (file-executable-p llminate-completion-server-binary)
    (user-error "Completion server binary not found: %s"
                llminate-completion-server-binary))
  (setq llminate-completion--server-ready nil)
  (let ((buf (get-buffer-create " *llminate-completion-server*")))
    (with-current-buffer buf (erase-buffer))
    (setq llminate-completion--server-process
          (start-process "llminate-completion-server"
                         buf
                         llminate-completion-server-binary))
    (set-process-query-on-exit-flag llminate-completion--server-process nil)
    (set-process-filter llminate-completion--server-process
                        #'llminate-completion--process-filter)
    (set-process-sentinel llminate-completion--server-process
                          #'llminate-completion--process-sentinel)
    (message "llminate-completion: server starting, waiting for listen...")))

(defun llminate-completion--check-health ()
  "Probe the /health endpoint for an externally-started server."
  (when llminate-completion--health-check-pending
    (cl-return-from llminate-completion--check-health))
  (setq llminate-completion--health-check-pending t)
  (let ((url-request-method "GET")
        (url (format "http://localhost:%d/health"
                     llminate-completion-server-port)))
    (url-retrieve
     url
     (lambda (status)
       (setq llminate-completion--health-check-pending nil)
       (if (plist-get status :error)
           (message "llminate-completion: server not reachable on port %d"
                    llminate-completion-server-port)
         (setq llminate-completion--server-ready t)
         (message "llminate-completion: server is ready"))
       (when (buffer-live-p (current-buffer))
         (kill-buffer (current-buffer))))
     nil t t)))

(defun llminate-completion-stop-server ()
  "Kill the completion server subprocess."
  (interactive)
  (when (and llminate-completion--server-process
             (process-live-p llminate-completion--server-process))
    (kill-process llminate-completion--server-process)
    (setq llminate-completion--server-process nil)
    (setq llminate-completion--server-ready nil)
    (message "llminate-completion: server stopped")))

(defun llminate-completion--ensure-server ()
  "Ensure the server is reachable.
If we manage the process, it becomes ready via the process filter.
If the server is external, do a one-shot health probe."
  (cond
   ;; We manage the process — filter handles readiness, nothing to do
   ((and llminate-completion--server-process
         (process-live-p llminate-completion--server-process))
    nil)
   ;; No managed process — probe for an external server (once)
   ((not llminate-completion--server-ready)
    (llminate-completion--check-health))))

;; --- Ghost text overlay ---

(defun llminate-completion--show-ghost (text)
  "Display TEXT as ghost text at point using an overlay."
  (llminate-completion--hide-ghost)
  (when (and text (not (string-empty-p text)))
    (setq llminate-completion--suggestion text)
    (setq llminate-completion--suggestion-point (point))
    (let* ((ov (make-overlay (point) (point) nil t nil))
           ;; Split into first line (displayed after cursor) and rest
           (lines (split-string text "\n"))
           (first-line (car lines))
           (rest-lines (cdr lines))
           (display-text
            (if rest-lines
                ;; Multi-line: first line as after-string on current line,
                ;; remaining lines displayed below
                (concat (propertize first-line
                                   'face 'llminate-completion-ghost-face)
                        "\n"
                        (propertize (string-join rest-lines "\n")
                                   'face 'llminate-completion-ghost-face))
              ;; Single line
              (propertize first-line
                          'face 'llminate-completion-ghost-face))))
      (overlay-put ov 'after-string display-text)
      (overlay-put ov 'llminate-ghost t)
      (overlay-put ov 'priority 1000)
      (setq llminate-completion--overlay ov))))

(defun llminate-completion--hide-ghost ()
  "Remove the ghost text overlay."
  (when llminate-completion--overlay
    (delete-overlay llminate-completion--overlay)
    (setq llminate-completion--overlay nil))
  (setq llminate-completion--suggestion nil)
  (setq llminate-completion--suggestion-point nil))

(defun llminate-completion--ghost-visible-p ()
  "Return non-nil if ghost text is currently visible."
  (and llminate-completion--overlay
       (overlay-buffer llminate-completion--overlay)))

;; --- Accept / dismiss ---

(defun llminate-completion-accept ()
  "Accept the current ghost text suggestion and insert it."
  (interactive)
  (if (llminate-completion--ghost-visible-p)
      (let ((text llminate-completion--suggestion))
        (llminate-completion--hide-ghost)
        (insert text))
    ;; No ghost text — fall through to the original Tab binding
    (let ((llminate-completion-mode nil))
      (call-interactively (key-binding (kbd "TAB"))))))

(defun llminate-completion-accept-word ()
  "Accept only the next word from the ghost text suggestion."
  (interactive)
  (if (llminate-completion--ghost-visible-p)
      (let* ((text llminate-completion--suggestion)
             ;; Extract the next word (including trailing whitespace)
             (word-end (or (string-match "\\b.+?\\b" text)
                           (length text)))
             ;; Find end of first word boundary
             (match-end (if (string-match "\\(?:\\sw\\|\\s_\\)+" text)
                            (match-end 0)
                          (length text)))
             (word (substring text 0 match-end))
             (rest (substring text match-end)))
        (llminate-completion--hide-ghost)
        (insert word)
        ;; Show remaining text as new ghost
        (when (not (string-empty-p rest))
          (llminate-completion--show-ghost rest)))
    ;; No ghost text — fall through
    (let ((llminate-completion-mode nil))
      (call-interactively (key-binding (kbd "M-f"))))))

(defun llminate-completion-dismiss ()
  "Dismiss the current ghost text suggestion."
  (interactive)
  (llminate-completion--hide-ghost))

;; --- Editor context collection ---

(defun llminate-completion--collect-context ()
  "Build an EditorContext alist from the current buffer state."
  (let* ((file-path (or (buffer-file-name) ""))
         (lang-id (llminate-completion--language-id))
         (content (buffer-substring-no-properties (point-min) (point-max)))
         (line (1- (line-number-at-pos (point) t)))  ; 0-indexed
         (character (- (point) (line-beginning-position))))
    `((file_path . ,file-path)
      (language_id . ,lang-id)
      (content . ,content)
      (cursor_position . ((line . ,line) (character . ,character))))))

;; --- HTTP request + SSE parsing ---

(defun llminate-completion--build-messages (context)
  "Build the messages array for a completion request given CONTEXT."
  (let* ((file-path (alist-get 'file_path context))
         (lang-id   (alist-get 'language_id context))
         (content   (alist-get 'content context))
         (cursor    (alist-get 'cursor_position context))
         (line      (alist-get 'line cursor))
         (char      (alist-get 'character cursor))
         (lines     (split-string content "\n"))
         (half      (/ llminate-completion-context-lines 2))
         (start-ln  (max 0 (- line half)))
         (end-ln    (min (1- (length lines)) (+ line half)))
         (window    (string-join (seq-subseq lines start-ln (1+ end-ln)) "\n")))
    (vector
     `((role . "user")
       (content . ,(format "You are a code completion engine for %s. \
Return ONLY the code that should be inserted at the cursor. \
Do not include explanations, markdown, or code fences.\n\n\
File: %s\nLanguage: %s\nCursor at line %d, column %d.\n\n```\n%s\n```\n\n\
Complete the code at the cursor position."
                           lang-id file-path lang-id line char window))))))

(defun llminate-completion--request (context callback)
  "Send a completion request with CONTEXT and call CALLBACK with the result text.
CALLBACK receives a single string argument (the accumulated completion)."
  (let* ((messages (llminate-completion--build-messages context))
         (payload `((messages . ,messages)
                    (provider . ,llminate-completion-provider)
                    (temperature . ,llminate-completion-temperature)
                    (max_completion_tokens . ,llminate-completion-max-tokens)
                    (editor_context . ,context)))
         (json-str (json-encode payload))
         (url (format "http://localhost:%d/complete" llminate-completion-server-port))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")
                                      ("Accept"       . "text/event-stream")))
         (url-request-data (encode-coding-string json-str 'utf-8)))
    (url-retrieve
     url
     (lambda (status cb)
       (if (plist-get status :error)
           (progn
             (message "llminate-completion: request error — %s"
                      (plist-get status :error))
             (when (buffer-live-p (current-buffer))
               (kill-buffer (current-buffer))))
         (let ((text (llminate-completion--parse-sse-response)))
           (when (buffer-live-p (current-buffer))
             (kill-buffer (current-buffer)))
           (when (and text (not (string-empty-p text)))
             (funcall cb text)))))
     (list callback)
     t t)))

(defun llminate-completion--parse-sse-response ()
  "Parse SSE events from the current response buffer and return accumulated text."
  (goto-char (point-min))
  (when (re-search-forward "\n\n" nil t)
    (let ((accumulated ""))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (when (string-prefix-p "data:" line)
            (let ((data (string-trim (substring line 5))))
              (unless (or (string-empty-p data)
                          (string= data "[DONE]"))
                (setq accumulated (concat accumulated data))))))
        (forward-line 1))
      accumulated)))

;; --- Automatic trigger ---

(defun llminate-completion--post-command ()
  "Hook run after each command to manage ghost text lifecycle."
  ;; Dismiss ghost text if the cursor moved away from the suggestion point
  (when (and (llminate-completion--ghost-visible-p)
             (not (eq (point) llminate-completion--suggestion-point)))
    (llminate-completion--hide-ghost))
  ;; Schedule a new completion request after typing
  (when (and (not (minibufferp))
             (derived-mode-p 'prog-mode)
             (buffer-file-name)
             (not (llminate-completion--ghost-visible-p)))
    ;; Kick off a health check if server readiness is unknown
    (unless llminate-completion--server-ready
      (llminate-completion--ensure-server))
    (let ((tick (buffer-chars-modified-tick)))
      (unless (eq tick llminate-completion--last-tick)
        (setq llminate-completion--last-tick tick)
        ;; Cancel any pending timer
        (when llminate-completion--debounce-timer
          (cancel-timer llminate-completion--debounce-timer))
        ;; Schedule new request
        (let ((buf (current-buffer))
              (pos (point)))
          (setq llminate-completion--debounce-timer
                (run-with-idle-timer
                 llminate-completion-debounce-delay nil
                 (lambda ()
                   (when (and (buffer-live-p buf)
                              (eq (current-buffer) buf)
                              (eq (point) pos)
                              llminate-completion--server-ready
                              (not (buffer-local-value
                                    'llminate-completion--request-pending buf)))
                     (with-current-buffer buf
                       (setq llminate-completion--request-pending t)
                       (let ((ctx (llminate-completion--collect-context)))
                         (llminate-completion--request
                          ctx
                          (lambda (text)
                            ;; url-retrieve runs this callback in the HTTP
                            ;; response buffer — switch back to the original
                            ;; editing buffer for overlay display
                            (when (buffer-live-p buf)
                              (with-current-buffer buf
                                (setq llminate-completion--request-pending nil)
                                (when (eq (point) pos)
                                  (llminate-completion--show-ghost text)))))))))))))))))

;; --- Minor mode ---

(defvar llminate-completion-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'llminate-completion-accept)
    (define-key map (kbd "M-f") #'llminate-completion-accept-word)
    (define-key map (kbd "C-g") #'llminate-completion-dismiss)
    map)
  "Keymap for `llminate-completion-mode'.")

;;;###autoload
(define-minor-mode llminate-completion-mode
  "Copilot-style ghost text completion using AI.
Shows inline suggestions as dimmed text after the cursor.
\\<llminate-completion-mode-map>
  \\[llminate-completion-accept] -- Accept the suggestion
  \\[llminate-completion-accept-word] -- Accept the next word
  \\[llminate-completion-dismiss] -- Dismiss the suggestion"
  :lighter " Ghost"
  :keymap llminate-completion-mode-map
  (if llminate-completion-mode
      (add-hook 'post-command-hook #'llminate-completion--post-command nil t)
    (remove-hook 'post-command-hook #'llminate-completion--post-command t)
    (llminate-completion--hide-ghost)))

;;;###autoload
(defun llminate-completion-enable ()
  "Enable ghost text completion in prog-mode buffers."
  (interactive)
  (add-hook 'prog-mode-hook #'llminate-completion-mode)
  (message "llminate-completion: ghost text enabled for programming modes"))

;;;###autoload
(defun llminate-completion-disable ()
  "Disable ghost text completion."
  (interactive)
  (remove-hook 'prog-mode-hook #'llminate-completion-mode)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when llminate-completion-mode
        (llminate-completion-mode -1))))
  (llminate-completion-stop-server)
  (message "llminate-completion: disabled"))

(provide 'llminate-completion)
;;; llminate-completion.el ends here
