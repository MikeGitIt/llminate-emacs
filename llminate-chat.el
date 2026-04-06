;;; llminate-chat.el --- Chat UI for llminate -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: llminate project
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Provides the chat interface for the llminate coding assistant:
;;  - *llminate Chat*  : read-only chat log with streaming display
;;  - *llminate Prompt* : multi-line input buffer
;;
;; Uses side-window display and overlays for in-progress streaming text.
;; EmacsCommand calls are shown inline: "[Emacs] command args -> result"
;; History navigation in the prompt buffer with M-p / M-n.

;;; Code:

(require 'cl-lib)
(require 'llminate-bridge)

;;;; Customization

(defgroup llminate-chat nil
  "Chat interface for the llminate coding assistant."
  :group 'llminate
  :prefix "llminate-chat-")

(defcustom llminate-chat-log-width 0.40
  "Width of the chat log side-window as a fraction of the frame."
  :type 'number
  :group 'llminate-chat)

(defcustom llminate-chat-prompt-height 5
  "Height (in lines) of the prompt side-window."
  :type 'integer
  :group 'llminate-chat)

(defcustom llminate-chat-timestamp-format "%H:%M:%S"
  "Format string for timestamps in the chat log."
  :type 'string
  :group 'llminate-chat)

(defcustom llminate-chat-max-history 100
  "Maximum number of prompt history entries to keep."
  :type 'integer
  :group 'llminate-chat)

(defcustom llminate-chat-render-backend 'markdown
  "Backend for rendering assistant markdown responses.
markdown — GFM font-lock with hidden markup (fast, good for streaming)
shr      — pandoc→HTML→shr rich rendering (best visual quality)
org      — pandoc→org with org-mode fontification"
  :type '(choice (const :tag "Markdown (gfm-view-mode font-lock)" markdown)
                 (const :tag "HTML (shr + pandoc)" shr)
                 (const :tag "Org (pandoc + org-mode)" org))
  :group 'llminate-chat)

;;;; Faces

(defface llminate-chat-user-face
  '((t :foreground "#61AFEF" :weight bold))
  "Face for the user label in the chat log."
  :group 'llminate-chat)

(defface llminate-chat-assistant-face
  '((t :foreground "#98C379" :weight bold))
  "Face for the assistant label in the chat log."
  :group 'llminate-chat)

(defface llminate-chat-streaming-face
  '((t :foreground "#ABB2BF" :slant italic))
  "Face for in-progress streaming text."
  :group 'llminate-chat)

(defface llminate-chat-tool-face
  '((t :foreground "#E5C07B" :weight bold))
  "Face for tool use entries."
  :group 'llminate-chat)

(defface llminate-chat-emacs-face
  '((t :foreground "#C678DD" :weight bold))
  "Face for EmacsCommand entries."
  :group 'llminate-chat)

(defface llminate-chat-error-face
  '((t :foreground "#E06C75" :weight bold))
  "Face for error entries."
  :group 'llminate-chat)

(defface llminate-chat-separator-face
  '((t :foreground "#4B5263"))
  "Face for separators between turns."
  :group 'llminate-chat)

(defface llminate-chat-timestamp-face
  '((t :foreground "#5C6370" :height 0.85))
  "Face for timestamps."
  :group 'llminate-chat)

;;;; Markdown rendering faces

(defface llminate-chat-md-code-face
  '((t :family "Menlo" :foreground "#E06C75" :background "#2C313C"))
  "Face for inline code spans (`code`)."
  :group 'llminate-chat)

(defface llminate-chat-md-code-block-face
  '((t :family "Menlo" :background "#2C313C" :extend t))
  "Face for fenced code blocks."
  :group 'llminate-chat)

(defface llminate-chat-md-code-block-header-face
  '((t :foreground "#5C6370" :background "#2C313C" :extend t))
  "Face for code block delimiters and language labels."
  :group 'llminate-chat)

(defface llminate-chat-md-bold-face
  '((t :weight bold))
  "Face for **bold** text."
  :group 'llminate-chat)

(defface llminate-chat-md-heading-1-face
  '((t :weight bold :height 1.3 :foreground "#61AFEF"))
  "Face for # H1 headings."
  :group 'llminate-chat)

(defface llminate-chat-md-heading-2-face
  '((t :weight bold :height 1.15 :foreground "#61AFEF"))
  "Face for ## H2 headings."
  :group 'llminate-chat)

(defface llminate-chat-md-heading-3-face
  '((t :weight bold :height 1.05 :foreground "#61AFEF"))
  "Face for ### H3+ headings."
  :group 'llminate-chat)

(defface llminate-chat-md-link-face
  '((t :foreground "#61AFEF" :underline t))
  "Face for [text](url) links."
  :group 'llminate-chat)

(defface llminate-chat-md-bullet-face
  '((t :foreground "#E5C07B"))
  "Face for list bullets and numbers."
  :group 'llminate-chat)

;;;; Markdown rendering backends

(defun llminate-chat--delete-invisible-text ()
  "Delete all characters with the `invisible' property in the current buffer.
Processes backwards to preserve earlier positions.  This is used after
gfm-view-mode font-lock to strip markup delimiters (**, #, etc.)
that are marked invisible, since the chat buffer lacks the matching
`buffer-invisibility-spec'."
  (let ((pos (point-max)))
    (while (> pos (point-min))
      (if (get-text-property (1- pos) 'invisible)
          (let ((start (or (previous-single-property-change pos 'invisible)
                           (point-min))))
            (delete-region start pos)
            (setq pos start))
        (setq pos (or (previous-single-property-change pos 'invisible)
                      (point-min)))))))

(defun llminate-chat--render-response (beg end &optional md-text)
  "Render the markdown response between BEG and END.
Dispatches to the backend selected by `llminate-chat-render-backend'.
Stores original markdown in `llminate-md-source' property for re-rendering.
If MD-TEXT is provided, use it as the source instead of reading from the buffer.
Returns the new END position (may differ if backend changes text length)."
  (let ((md-text (or md-text (buffer-substring-no-properties beg end))))
    (condition-case err
        (pcase llminate-chat-render-backend
          ('markdown (llminate-chat--render-via-markdown beg end md-text))
          ('shr      (llminate-chat--render-via-shr beg end md-text))
          ('org      (llminate-chat--render-via-org beg end md-text))
          (_         end))
      (error
       (message "[llminate] Render error (%s): %s"
                llminate-chat-render-backend (error-message-string err))
       end))))

(defun llminate-chat--render-via-markdown (beg end md-text)
  "Render MD-TEXT via gfm-view-mode font-lock.  Replace BEG..END.
Strips invisible markup characters so faces render correctly in the
chat buffer without needing a matching `buffer-invisibility-spec'.
Returns new end position."
  (let ((rendered
         (with-temp-buffer
           (insert md-text)
           (delay-mode-hooks (gfm-view-mode))
           (setq-local markdown-fontify-code-blocks-natively t)
           (setq-local markdown-hide-markup t)
           (font-lock-ensure)
           ;; Actually delete chars marked invisible (**, #, ```, etc.)
           ;; so they don't show as raw markup in the chat buffer
           (llminate-chat--delete-invisible-text)
           (buffer-string))))
    (delete-region beg end)
    (goto-char beg)
    (insert rendered)
    (let ((new-end (point)))
      (put-text-property beg new-end 'llminate-md-source md-text)
      new-end)))

(defun llminate-chat--render-via-shr (beg end md-text)
  "Render MD-TEXT via pandoc->HTML->shr.  Replace BEG..END.
Returns new end position."
  (let* ((html (with-temp-buffer
                 (insert md-text)
                 (let ((exit-code
                        (call-process-region (point-min) (point-max)
                                             "pandoc" t t nil
                                             "-f" "markdown" "-t" "html")))
                   (unless (eq exit-code 0)
                     (error "pandoc exited with code %s" exit-code)))
                 (buffer-string)))
         (rendered (with-temp-buffer
                     (let ((dom (with-temp-buffer
                                  (insert html)
                                  (libxml-parse-html-region (point-min) (point-max)))))
                       (shr-insert-document dom)
                       (buffer-string)))))
    (delete-region beg end)
    (goto-char beg)
    (insert rendered)
    (let ((new-end (point)))
      (put-text-property beg new-end 'llminate-md-source md-text)
      new-end)))

(defun llminate-chat--render-via-org (beg end md-text)
  "Render MD-TEXT via pandoc->org->org-mode font-lock.  Replace BEG..END.
Returns new end position."
  (let* ((org-text (with-temp-buffer
                     (insert md-text)
                     (let ((exit-code
                            (call-process-region (point-min) (point-max)
                                                 "pandoc" t t nil
                                                 "-f" "markdown" "-t" "org")))
                       (unless (eq exit-code 0)
                         (error "pandoc exited with code %s" exit-code)))
                     (buffer-string)))
         (rendered (with-temp-buffer
                     (insert org-text)
                     (delay-mode-hooks (org-mode))
                     (font-lock-ensure)
                     (buffer-string))))
    (delete-region beg end)
    (goto-char beg)
    (insert rendered)
    (let ((new-end (point)))
      (put-text-property beg new-end 'llminate-md-source md-text)
      new-end)))

(defun llminate-chat-set-render-backend (backend)
  "Set the markdown rendering BACKEND and re-render all responses."
  (interactive
   (list (intern (completing-read "Render backend: "
                                  '("markdown" "shr" "org")
                                  nil t))))
  (setq llminate-chat-render-backend backend)
  (llminate-chat-rerender-all)
  (message "[llminate] Render backend: %s" backend))

(defun llminate-chat-rerender-all ()
  "Re-render all assistant responses using the current backend.
Handles both tagged regions (with `llminate-md-source' property) and
untagged regions from before the rendering code was loaded.  Untagged
responses are found by searching for \"Assistant: \" labels and locating
the response text up to the timestamp line."
  (interactive)
  (let ((buf (llminate-chat--log-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (regions nil))
        ;; Pass 1: collect tagged regions (have llminate-md-source)
        (let ((pos (point-min)))
          (while (< pos (point-max))
            (let ((source (get-text-property pos 'llminate-md-source)))
              (if source
                  (let ((region-end (next-single-property-change
                                     pos 'llminate-md-source nil (point-max))))
                    (push (list pos region-end source) regions)
                    (setq pos region-end))
                (setq pos (or (next-single-property-change
                               pos 'llminate-md-source nil (point-max))
                              (point-max)))))))
        ;; Pass 2: find untagged assistant responses
        ;; Pattern: "Assistant: " <response> "\n  HH:MM:SS\n"
        (save-excursion
          (goto-char (point-min))
          (while (search-forward "Assistant: " nil t)
            (let ((resp-beg (point)))
              (unless (get-text-property resp-beg 'llminate-md-source)
                (let ((resp-end
                       (save-excursion
                         (if (re-search-forward
                              "\n  [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\n" nil t)
                             (match-beginning 0)
                           (point-max)))))
                  (when (< resp-beg resp-end)
                    (push (list resp-beg resp-end nil) regions)))))))
        ;; Process in reverse position order so edits don't shift earlier regions
        (setq regions (sort regions (lambda (a b) (> (car a) (car b)))))
        (let ((count 0))
          (dolist (region regions)
            (let ((beg (nth 0 region))
                  (end (nth 1 region))
                  (source (nth 2 region)))
              (llminate-chat--render-response
               beg end
               (or source (buffer-substring-no-properties beg end)))
              (cl-incf count)))
          (message "[llminate] Re-rendered %d response(s)" count))))))

;;;; Chat log mode

(defvar llminate-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q")     #'quit-window)
    (define-key map (kbd "g")     #'llminate-chat-refresh)
    (define-key map (kbd "C-c C-c") #'llminate-bridge-stop)
    (define-key map (kbd "G")     #'end-of-buffer)
    map)
  "Keymap for `llminate-chat-mode'.")

(define-derived-mode llminate-chat-mode special-mode "llminate Chat"
  "Major mode for the llminate chat log buffer.
Read-only display of the conversation with streaming support.

\\{llminate-chat-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type nil)
  (setq-local buffer-read-only t))

;;;; Prompt mode

(defvar llminate-chat--prompt-history nil
  "List of previous prompts (newest first).")

(defvar llminate-chat--prompt-history-index -1
  "Current index into the prompt history (-1 means not navigating).")

(defvar llminate-chat-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'llminate-chat-send)
    (define-key map (kbd "C-c C-k") #'llminate-chat-cancel)
    (define-key map (kbd "M-p")     #'llminate-chat-prompt-history-prev)
    (define-key map (kbd "M-n")     #'llminate-chat-prompt-history-next)
    (define-key map (kbd "<up>")    #'llminate-chat-prompt-up)
    (define-key map (kbd "<down>")  #'llminate-chat-prompt-down)
    map)
  "Keymap for `llminate-chat-prompt-mode'.")

(define-derived-mode llminate-chat-prompt-mode text-mode "llminate Prompt"
  "Major mode for the llminate prompt input buffer.
Multi-line input area.

Keybindings:
  C-c C-c  -- Send the current prompt
  C-c C-k  -- Cancel / clear the prompt
  Up/M-p   -- Previous prompt from history (Up at first line)
  Down/M-n -- Next prompt from history (Down at last line)
  RET      -- Insert newline (multi-line input)

\\{llminate-chat-prompt-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;;;; Message log (for chat log export)

(defvar llminate-chat--message-log nil
  "Ordered list of messages in the current conversation.
Each entry is a plist with keys :role, :content, :timestamp.
Appended to by `llminate-chat-send' (user) and
`llminate-chat--end-assistant-turn' (assistant).")

(defun llminate-chat--log-message (role content)
  "Append a message with ROLE and CONTENT to the message log."
  (setq llminate-chat--message-log
        (append llminate-chat--message-log
                (list (list :role role
                            :content content
                            :timestamp (format-time-string "%Y-%m-%dT%H:%M:%S"))))))

(defun llminate-chat-message-log ()
  "Return the current message log (list of plists)."
  llminate-chat--message-log)

(defun llminate-chat-clear-message-log ()
  "Clear the message log (e.g., on session restart)."
  (setq llminate-chat--message-log nil))

(defvar llminate-chat-turn-end-hook nil
  "Hook run after each assistant turn ends and is logged.
Used by `llminate-session' to trigger chat log export.")

;;;; Internal state

(defvar llminate-chat--current-turn nil
  "Plist tracking the current turn state:
  :role       - \"user\" or \"assistant\"
  :start-pos  - buffer position where this turn's text begins
  :streaming  - t while still receiving chunks")

;; -- Streaming state (overlay-free, batched insertion) --

(defvar llminate-chat--stream-start-marker nil
  "Marker at the beginning of the current streaming region.
Used to apply/remove face properties when the turn ends.")

(defvar llminate-chat--stream-insert-marker nil
  "Marker at the insertion point for streaming text.
Has right-gravity so it advances automatically on insert.")

(defvar llminate-chat--stream-pending ""
  "Text accumulated between flush timer ticks.
Flushed into the buffer every 30 ms by `llminate-chat--flush-stream'.")

(defvar llminate-chat--stream-flush-timer nil
  "Timer for batched text insertion during streaming (~30 ms).")

;;;; Buffer helpers

(defun llminate-chat--log-buffer ()
  "Get or create the *llminate Chat* buffer."
  (let ((buf (get-buffer-create "*llminate Chat*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'llminate-chat-mode)
        (llminate-chat-mode)))
    buf))

(defun llminate-chat--prompt-buffer ()
  "Get or create the *llminate Prompt* buffer."
  (let ((buf (get-buffer-create "*llminate Prompt*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'llminate-chat-prompt-mode)
        (llminate-chat-prompt-mode)))
    buf))

;;;; Chat log insertion helpers

(defun llminate-chat--insert (text &optional face)
  "Insert TEXT into the chat log with optional FACE.
Must be called with the log buffer current and inhibit-read-only t."
  (let ((start (point)))
    (insert text)
    (when face
      (add-text-properties start (point) (list 'face face)))))

(defun llminate-chat--insert-timestamp ()
  "Insert a right-aligned timestamp on a new line."
  (let ((ts (format-time-string llminate-chat-timestamp-format)))
    (llminate-chat--insert (format "  %s\n" ts) 'llminate-chat-timestamp-face)))

(defun llminate-chat--insert-separator ()
  "Insert a visual separator between turns."
  (llminate-chat--insert
   (concat (make-string 40 ?─) "\n") 'llminate-chat-separator-face))

(defun llminate-chat--append-to-log (label text &optional face)
  "Append a LABEL + TEXT entry to the chat log.
FACE is applied to the TEXT portion."
  (let ((buf (llminate-chat--log-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (at-end (eobp))
            (win (get-buffer-window buf)))
        (save-excursion
          (goto-char (point-max))
          (insert label)
          (when face
            (let ((start (point)))
              (insert text)
              (add-text-properties start (point) (list 'face face)))
            (goto-char (point-max)))
          (unless face
            (insert text))
          (insert "\n"))
        ;; Auto-scroll if we were at the end
        (when (and win at-end)
          (with-selected-window win
            (goto-char (point-max))
            (recenter -1)))))))

;;;; Streaming support

(defun llminate-chat--begin-assistant-turn ()
  "Start a new assistant turn in the chat log.
Uses markers instead of an overlay — no per-token `move-overlay'
calls that force redisplay of the entire streaming region."
  (let ((buf (llminate-chat--log-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (llminate-chat--insert
         "Assistant: " 'llminate-chat-assistant-face)
        ;; Record where streaming content begins
        (let ((pos (point)))
          (setq llminate-chat--stream-start-marker (copy-marker pos))
          (setq llminate-chat--stream-insert-marker (copy-marker pos t)) ; right-gravity
          (setq llminate-chat--stream-pending "")
          (setq llminate-chat--current-turn
                (list :role "assistant"
                      :start-pos pos
                      :streaming t)))))))

(defvar llminate-chat--scroll-timer nil
  "Timer for batched auto-scroll during streaming (~50 ms).")

(defun llminate-chat--stream-chunk (text)
  "Append TEXT to the pending stream buffer.
Actual buffer insertion is batched — text accumulates in
`llminate-chat--stream-pending' and is flushed every 30 ms by
`llminate-chat--flush-stream'.  This reduces per-token buffer
operations from hundreds/sec to ~33/sec."
  (when (and text llminate-chat--stream-insert-marker)
    (setq llminate-chat--stream-pending
          (concat llminate-chat--stream-pending text))
    ;; Schedule a flush if one isn't already pending
    (unless llminate-chat--stream-flush-timer
      (setq llminate-chat--stream-flush-timer
            (run-at-time 0.03 nil #'llminate-chat--flush-stream)))))

(defun llminate-chat--flush-stream ()
  "Flush accumulated streaming text into the chat log buffer.
Applies `llminate-chat-streaming-face' as a text property (not an
overlay) so no per-insertion redisplay of the entire region."
  (setq llminate-chat--stream-flush-timer nil)
  (when (and (> (length llminate-chat--stream-pending) 0)
             llminate-chat--stream-insert-marker)
    (let ((buf (llminate-chat--log-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                (text llminate-chat--stream-pending))
            (setq llminate-chat--stream-pending "")
            (goto-char llminate-chat--stream-insert-marker)
            (let ((start (point)))
              (insert text)
              (add-text-properties start (point)
                                   (list 'face 'llminate-chat-streaming-face)))))
        ;; Schedule auto-scroll (separate timer, 50 ms)
        (unless llminate-chat--scroll-timer
          (setq llminate-chat--scroll-timer
                (run-at-time 0.05 nil #'llminate-chat--do-scroll)))))))

(defun llminate-chat--do-scroll ()
  "Perform the actual auto-scroll of the chat log window.
Called from a short timer to batch rapid streaming updates."
  (setq llminate-chat--scroll-timer nil)
  (let* ((buf (llminate-chat--log-buffer))
         (win (get-buffer-window buf)))
    (when win
      (with-selected-window win
        (goto-char (point-max))
        (recenter -1)))))

(defun llminate-chat--end-assistant-turn ()
  "Finalize the current streaming assistant turn.
Flushes remaining text, removes the streaming face, adds
timestamp + separator, and cleans up markers."
  ;; 1. Cancel pending timers
  (when llminate-chat--stream-flush-timer
    (cancel-timer llminate-chat--stream-flush-timer)
    (setq llminate-chat--stream-flush-timer nil))
  (when llminate-chat--scroll-timer
    (cancel-timer llminate-chat--scroll-timer)
    (setq llminate-chat--scroll-timer nil))
  ;; 2. Flush any remaining accumulated text
  (when (and llminate-chat--stream-pending
             (> (length llminate-chat--stream-pending) 0))
    (setq llminate-chat--stream-flush-timer nil) ; ensure flush doesn't re-schedule
    (llminate-chat--flush-stream))
  ;; 3. Cancel scroll timer that flush may have set
  (when llminate-chat--scroll-timer
    (cancel-timer llminate-chat--scroll-timer)
    (setq llminate-chat--scroll-timer nil))
  ;; 4. Finalize in the buffer
  (when llminate-chat--stream-start-marker
    (let ((buf (llminate-chat--log-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                (beg (marker-position llminate-chat--stream-start-marker))
                (end (marker-position llminate-chat--stream-insert-marker)))
            ;; Remove the italic streaming face from the completed response
            (when (< beg end)
              (remove-text-properties beg end '(face nil)))
            ;; Render markdown using the selected backend
            (let ((new-end (if (< beg end)
                               (llminate-chat--render-response beg end)
                             end)))
              ;; Append newline, timestamp, separator after the rendered response
              (goto-char new-end)
              (insert "\n")
              (llminate-chat--insert-timestamp)
              (llminate-chat--insert-separator)))))))
  ;; 5. Clean up markers
  (when llminate-chat--stream-start-marker
    (set-marker llminate-chat--stream-start-marker nil)
    (setq llminate-chat--stream-start-marker nil))
  (when llminate-chat--stream-insert-marker
    (set-marker llminate-chat--stream-insert-marker nil)
    (setq llminate-chat--stream-insert-marker nil))
  (setq llminate-chat--stream-pending "")
  (setq llminate-chat--current-turn nil)
  ;; 6. Log the assistant message for chat export
  (let ((text (bound-and-true-p llminate-bridge--accumulated-text)))
    (when (and text (not (string-empty-p text)))
      (llminate-chat--log-message "assistant" text)))
  ;; 7. Auto-save chat log (runs the export hook if configured)
  (run-hooks 'llminate-chat-turn-end-hook)
  ;; 8. Final scroll
  (llminate-chat--do-scroll))

;;;; Side-window display

(defun llminate-chat-show ()
  "Show the llminate chat panels as side windows."
  (interactive)
  (let ((log-buf (llminate-chat--log-buffer))
        (prompt-buf (llminate-chat--prompt-buffer)))
    ;; Chat log on the right
    (display-buffer-in-side-window
     log-buf
     `((side . right)
       (window-width . ,llminate-chat-log-width)
       (slot . 0)
       (window-parameters . ((no-delete-other-windows . t)))))
    ;; Prompt at the bottom
    (display-buffer-in-side-window
     prompt-buf
     `((side . bottom)
       (window-height . ,llminate-chat-prompt-height)
       (slot . 1)
       (window-parameters . ((no-delete-other-windows . t)))))
    ;; Focus the prompt
    (when-let* ((win (get-buffer-window prompt-buf)))
      (select-window win))
    (message "[llminate] Chat panel ready — C-c C-c to send")))

(defun llminate-chat-hide ()
  "Hide the llminate chat panels."
  (interactive)
  (dolist (name '("*llminate Chat*" "*llminate Prompt*"))
    (when-let* ((win (get-buffer-window name)))
      (delete-window win))))

(defun llminate-chat-toggle ()
  "Toggle the chat panel visibility."
  (interactive)
  (if (get-buffer-window "*llminate Chat*")
      (llminate-chat-hide)
    (llminate-chat-show)))

(defun llminate-chat-refresh ()
  "Placeholder for refreshing the chat display."
  (interactive)
  (message "[llminate] Chat log refreshed"))

;;;; Sending prompts

(defvar llminate-chat--assistant-turn-started nil
  "Non-nil when an assistant turn has been opened for the current response.")

(defun llminate-chat-send ()
  "Read the prompt buffer, send to llminate, display the conversation."
  (interactive)
  (let* ((prompt-buf (llminate-chat--prompt-buffer))
         (prompt (with-current-buffer prompt-buf
                   (string-trim (buffer-string)))))
    (when (string-empty-p prompt)
      (user-error "Empty prompt"))
    ;; Save to history
    (llminate-chat--history-push prompt)
    ;; Clear the prompt buffer
    (with-current-buffer prompt-buf
      (erase-buffer))
    ;; Insert the user message into the chat log
    (let ((buf (llminate-chat--log-buffer)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (llminate-chat--insert "You: " 'llminate-chat-user-face)
          (let ((msg-beg (point)))
            (insert prompt "\n")
            ;; Render markdown in the user message too
            (llminate-chat--render-response msg-beg (point)))
          (llminate-chat--insert-timestamp)
          (llminate-chat--insert-separator))))
    ;; Log the user message for chat export
    (llminate-chat--log-message "user" prompt)
    ;; Mark that the assistant turn is NOT yet started — it will be
    ;; created lazily when the first assistant message chunk arrives.
    (setq llminate-chat--assistant-turn-started nil)
    ;; Send to the bridge — use context-enriched variant so the AI
    ;; knows about the Emacs environment and available EmacsCommands
    (llminate-bridge-send-prompt-with-context prompt #'llminate-chat--response-handler)))

(defun llminate-chat--ensure-assistant-turn ()
  "Start the assistant turn if it hasn't been started yet for this response."
  (unless llminate-chat--assistant-turn-started
    (llminate-chat--begin-assistant-turn)
    (setq llminate-chat--assistant-turn-started t)))

(defun llminate-chat--tool-use-detail (name input)
  "Build a clean display string for a tool-use event.
NAME is the tool or command name.  INPUT is a plist of parameters.
Returns a compact, readable string."
  (cond
   ;; Bash-style command: show just the command, not the JSON wrapper
   ((and (stringp name)
         (or (string-prefix-p "bash " name)
             (string-prefix-p "Bash" name)
             ;; Codex sends the full command as the name
             (string-match-p "^[a-z/].*" name)))
    ;; If input has a :command field identical to name, don't repeat it
    (let ((cmd (and (listp input) (plist-get input :command))))
      (if (and cmd (string= cmd name))
          (format "Bash: %s" (llminate-chat--shorten-command name))
        (format "%s" (llminate-chat--shorten-command name)))))
   ;; Named tool (Read, Grep, Edit, etc.) with input parameters
   ((and (stringp name) input)
    (let* ((file (or (and (listp input) (plist-get input :file_path))
                     (and (listp input) (plist-get input :path))
                     (and (listp input) (plist-get input :pattern))))
           (short (if (and file (stringp file))
                      (abbreviate-file-name file)
                    (let ((json-encoding-pretty-print nil))
                      (json-encode input)))))
      (format "%s %s" name
              (if (> (length short) 80)
                  (concat (substring short 0 80) "...")
                short))))
   ;; Fallback
   (t (or name "unknown tool"))))

(defun llminate-chat--shorten-command (cmd)
  "Shorten a shell command CMD for display.
Strips `bash -lc' wrapper and truncates to 100 chars."
  (let ((cleaned cmd))
    ;; Strip common shell wrappers
    (when (string-match "^bash\\s+-[a-z]*c\\s+\\(.+\\)" cleaned)
      (setq cleaned (match-string 1 cleaned)))
    ;; Strip outer quotes
    (when (and (> (length cleaned) 1)
               (memq (aref cleaned 0) '(?\" ?'))
               (eq (aref cleaned 0) (aref cleaned (1- (length cleaned)))))
      (setq cleaned (substring cleaned 1 -1)))
    (if (> (length cleaned) 100)
        (concat (substring cleaned 0 100) "...")
      cleaned)))

(defun llminate-chat--first-meaningful-line (text)
  "Return the first non-blank line from TEXT."
  (if (and text (stringp text))
      (let ((lines (split-string text "\n" t "\\s-*")))
        (or (car lines) ""))
    ""))

(defun llminate-chat--response-handler (type data)
  "Handle bridge response events of TYPE with DATA."
  (cond
   ((eq type 'message)
    ;; Streaming text chunk — lazily start the assistant turn on first chunk
    (when data
      (llminate-chat--ensure-assistant-turn)
      (llminate-chat--stream-chunk data)))

   ((eq type 'tool-use)
    ;; Display tool invocation — clean, compact format
    (llminate-chat--ensure-assistant-turn)
    (let* ((name (plist-get data :name))
           (input (plist-get data :input))
           ;; Extract the most useful display string from input
           (detail (llminate-chat--tool-use-detail name input)))
      (llminate-chat--append-to-log
       (propertize "[Tool] " 'face 'llminate-chat-tool-face)
       detail
       'llminate-chat-tool-face)))

   ((eq type 'tool-result)
    ;; Display tool result — single line, truncated
    (let* ((output (if (stringp data)
                       data
                     (let ((json-encoding-pretty-print nil))
                       (json-encode data))))
           ;; Take first non-blank line only
           (first-line (llminate-chat--first-meaningful-line output))
           (truncated (if (> (length first-line) 120)
                         (concat (substring first-line 0 120) "...")
                       first-line)))
      (llminate-chat--append-to-log "  => " truncated)))

   ((eq type 'tool-approval)
    ;; Show that approval is being requested
    (llminate-chat--ensure-assistant-turn)
    (let ((tool-name (plist-get data :tool_name)))
      (llminate-chat--append-to-log
       (propertize "[Approval] " 'face 'llminate-chat-tool-face)
       (format "Waiting for approval: %s" tool-name))))

   ((eq type 'end)
    ;; Finalize the assistant turn (only if one was started)
    (when llminate-chat--assistant-turn-started
      (llminate-chat--end-assistant-turn)
      (setq llminate-chat--assistant-turn-started nil)))

   ((eq type 'error)
    ;; Display error
    (when llminate-chat--assistant-turn-started
      (llminate-chat--end-assistant-turn)
      (setq llminate-chat--assistant-turn-started nil))
    (llminate-chat--append-to-log
     (propertize "[Error] " 'face 'llminate-chat-error-face)
     (or data "Unknown error")
     'llminate-chat-error-face))))

;;;; EmacsCommand display (hooked into the bridge)

(defun llminate-chat--display-emacs-eval (command args request-id)
  "Display an EmacsEval event in the chat log.
COMMAND, ARGS, and REQUEST-ID describe the call."
  (llminate-chat--append-to-log
   (propertize "[Emacs] " 'face 'llminate-chat-emacs-face)
   (format "%s%s"
           command
           (if args (format " %S" args) ""))
   'llminate-chat-emacs-face))

;; Register the hook
(add-hook 'llminate-bridge-emacs-eval-hook #'llminate-chat--display-emacs-eval)

;;;; Session resume — replay previous conversation into the chat log

(defun llminate-chat--on-session-resume (messages)
  "Replay MESSAGES (list of plists) into the chat log buffer.
Each entry has :role, :content, :timestamp."
  ;; Clear old state
  (llminate-chat-clear-message-log)
  (let ((buf (llminate-chat--log-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (llminate-chat--insert
         (propertize "── Resumed session ──\n\n"
                     'face 'llminate-chat-separator-face))
        (dolist (msg messages)
          (let ((role (plist-get msg :role))
                (content (plist-get msg :content)))
            (cond
             ((string= role "user")
              (llminate-chat--insert "You: " 'llminate-chat-user-face)
              (let ((msg-beg (point)))
                (insert (or content "") "\n")
                (llminate-chat--render-response msg-beg (point)))
              (llminate-chat--insert-separator))
             ((string= role "assistant")
              (llminate-chat--insert "Assistant: " 'llminate-chat-assistant-face)
              (let ((msg-beg (point)))
                (insert (or content "") "\n")
                (llminate-chat--render-response msg-beg (point)))
              (llminate-chat--insert-separator)))))
        ;; Scroll to bottom
        (goto-char (point-max))
        (let ((win (get-buffer-window buf)))
          (when win (set-window-point win (point-max))))))
    ;; Rebuild the message log for export
    (dolist (msg messages)
      (llminate-chat--log-message
       (plist-get msg :role)
       (or (plist-get msg :content) "")))))

(add-hook 'llminate-bridge-session-resume-hook #'llminate-chat--on-session-resume)

;;;; Prompt history navigation — arrow keys + M-p/M-n

(defun llminate-chat-prompt-up ()
  "In the prompt buffer: navigate history when at the first line.
Otherwise move the cursor up normally.  This mirrors shell/REPL
behavior — arrow keys cycle history at buffer boundaries."
  (interactive)
  (if (= (line-number-at-pos) 1)
      (llminate-chat-prompt-history-prev)
    (forward-line -1)))

(defun llminate-chat-prompt-down ()
  "In the prompt buffer: navigate history when at the last line.
Otherwise move the cursor down normally."
  (interactive)
  (if (= (line-number-at-pos) (line-number-at-pos (point-max)))
      (llminate-chat-prompt-history-next)
    (forward-line 1)))

(defun llminate-chat--history-push (prompt)
  "Add PROMPT to the history, respecting `llminate-chat-max-history'."
  (push prompt llminate-chat--prompt-history)
  (when (> (length llminate-chat--prompt-history) llminate-chat-max-history)
    (setq llminate-chat--prompt-history
          (cl-subseq llminate-chat--prompt-history
                     0 llminate-chat-max-history)))
  (setq llminate-chat--prompt-history-index -1))

(defun llminate-chat-prompt-history-prev ()
  "Navigate to the previous entry in prompt history."
  (interactive)
  (when llminate-chat--prompt-history
    (let ((new-index (min (1+ llminate-chat--prompt-history-index)
                          (1- (length llminate-chat--prompt-history)))))
      (setq llminate-chat--prompt-history-index new-index)
      (let ((entry (nth new-index llminate-chat--prompt-history)))
        (erase-buffer)
        (insert entry)))))

(defun llminate-chat-prompt-history-next ()
  "Navigate to the next entry in prompt history."
  (interactive)
  (cond
   ((< llminate-chat--prompt-history-index 0)
    ;; Already at the newest — do nothing
    nil)
   ((= llminate-chat--prompt-history-index 0)
    ;; Return to empty prompt
    (setq llminate-chat--prompt-history-index -1)
    (erase-buffer))
   (t
    (cl-decf llminate-chat--prompt-history-index)
    (let ((entry (nth llminate-chat--prompt-history-index
                      llminate-chat--prompt-history)))
      (erase-buffer)
      (insert entry)))))

(defun llminate-chat-cancel ()
  "Clear the prompt buffer."
  (interactive)
  (erase-buffer)
  (setq llminate-chat--prompt-history-index -1)
  (message "[llminate] Prompt cleared"))

(provide 'llminate-chat)

;;; llminate-chat.el ends here
