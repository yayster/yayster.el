;;; yayster.el --- El Yayster: a resident LLM that inhabits Emacs -*- lexical-binding: t; -*-

;; Author: David Kayal
;; Version: 0.2.1
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; A runnable v0.  Makes Emacs a *body* an LLM inhabits, not a *mouth* that
;; talks to one.  Wired to any OpenAI-compatible endpoint — great with a local
;; Ollama, so it needs no OpenAI and no cloud.
;;
;; Five parts:
;;   1. CAPABILITIES     — gated elisp the agent may call (its hands).
;;   2. PERMISSION GATE  — read-only auto-approves; mutating always asks.
;;   3. SITUATING PROMPT — identity + live environment + tool manifest.
;;   4. AGENT LOOP       — async ReAct: ACTION/ARGS -> execute -> RESULT -> repeat.
;;   5. AWAKEN           — seat a resident operator at boot (init.el).
;;
;; Transport is a direct curl POST to an OpenAI-compatible /chat/completions
;; endpoint, so it needs no external elisp deps.
;;
;; Quick start:
;;   (require 'yayster)
;;   (yayster-awaken)
;;   M-x yayster-step  ->  "what buffers are open?"
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup yayster nil
  "El Yayster — a resident LLM operator that inhabits Emacs."
  :group 'tools)

(defcustom yayster-endpoint "http://localhost:11434/v1/chat/completions"
  "OpenAI-compatible chat endpoint.  Default: a local Ollama on this machine.
Point this at any OpenAI-compatible /chat/completions server."
  :type 'string :group 'yayster)

(defcustom yayster-model "qwen3:8b"
  "Model served by the endpoint.  Change to whatever your Ollama has pulled."
  :type 'string :group 'yayster)

(defcustom yayster-api-key nil
  "Optional bearer token.  Ollama ignores it; required by hosted APIs.
When set, written to a mode-0600 temp header file and passed to curl as
`-H @FILE' so the secret never appears on the process command line."
  :type '(choice (const nil) string) :group 'yayster)

(defcustom yayster-timeout 300
  "Seconds to wait for a single model response."
  :type 'integer :group 'yayster)

(defcustom yayster-max-steps 12
  "Safety valve: max tool-execution cycles per user turn."
  :type 'integer :group 'yayster)

(defcustom yayster-command-timeout 30
  "Seconds `run_command' may block before it is aborted."
  :type 'integer :group 'yayster)

(defcustom yayster-command-max-bytes 65536
  "Maximum bytes of `run_command' output returned to the model."
  :type 'integer :group 'yayster)

(defcustom yayster-auto-approve-readonly t
  "When non-nil, read-only capabilities run without a prompt.
Mutating capabilities ALWAYS prompt regardless of this setting."
  :type 'boolean :group 'yayster)

(defcustom yayster-confirm-function #'yayster--confirm
  "Function called with a PROMPT string to approve a mutating capability.
Must return non-nil to approve.  The prompt includes the capability name
and the full argument payload (no truncation), so a rebind to `y-or-n-p'
is not blind.  The default also shows a GUI dialog on graphical frames."
  :type 'function :group 'yayster)

(defcustom yayster-use-dialog t
  "When non-nil and the frame is graphical, approvals use a GUI dialog box.
Falls back to the *yayster-permission* buffer + a minibuffer y/n prompt on
terminal frames or when nil."
  :type 'boolean :group 'yayster)

(defcustom yayster-context-size 8192
  "Assumed context-window size (tokens) of the current model.
Shown in the *yayster* header line.  When talking to an Ollama endpoint this is
auto-detected via /api/show on `yayster-awaken' and host switches; set it
manually for other servers."
  :type 'integer :group 'yayster)

;;; Token accounting (updated as turns run; shown in the header line).
(defvar yayster--turn-prompt 0 "Prompt tokens used in the current turn.")
(defvar yayster--turn-completion 0 "Completion tokens used in the current turn.")
(defvar yayster--turn-calls 0 "Model calls made in the current turn.")
(defvar yayster--session-tokens 0 "Total tokens used since load/awaken.")
(defvar yayster--last-prompt-tokens 0
  "Prompt tokens on the most recent call ~= current context occupancy.")

(defcustom yayster-hosts
  '(("local" "http://localhost:11434/v1/chat/completions" "qwen3:8b"))
  "Known LLM hosts you can switch between: (NAME ENDPOINT DEFAULT-MODEL).
Each entry is one OpenAI-compatible endpoint (e.g. an Ollama server).
Switch at runtime with `\\[yayster-use-host]'.

Multi-host example — put this in your init.el to fan out across boxes:

  (setq yayster-hosts
        \\='((\"workstation\" \"http://gpu-box.local:11434/v1/chat/completions\" \"qwen3:32b\")
          (\"laptop\"      \"http://localhost:11434/v1/chat/completions\"    \"qwen3:8b\")))"
  :type '(alist :key-type string :value-type (group string string))
  :group 'yayster)

(defun yayster--endpoint-root (endpoint)
  "Return scheme://host:port for ENDPOINT (strips the path)."
  (if (string-match "\\`\\(https?://[^/]+\\)" endpoint)
      (match-string 1 endpoint)
    endpoint))

(defun yayster--fetch-context-size ()
  "Best-effort: ask an Ollama endpoint (/api/show) for the model context length.
Sets `yayster-context-size' on success.  Silent; synchronous; 5s timeout."
  (ignore-errors
    (let* ((root (yayster--endpoint-root yayster-endpoint))
           (url  (concat root "/api/show"))
           (tmp  (make-temp-file "yy-show" nil ".json")))
      (unwind-protect
          (progn
            (with-temp-file tmp
              (insert (json-encode `(("model" . ,yayster-model)))))
            (with-temp-buffer
              (when (zerop (call-process "curl" nil t nil "-s" "--max-time" "5"
                                         url "-H" "Content-Type: application/json"
                                         "--data" (concat "@" tmp)))
                (goto-char (point-min))
                (let* ((json-object-type 'alist)
                       (resp (json-read))
                       (info (alist-get 'model_info resp))
                       (ctx nil))
                  (dolist (pair info)
                    (when (and (symbolp (car pair))
                               (string-suffix-p "context_length"
                                                (symbol-name (car pair)))
                               (numberp (cdr pair)))
                      (setq ctx (cdr pair))))
                  (when ctx (setq yayster-context-size ctx))))))
        (ignore-errors (delete-file tmp))))))

(defun yayster-use-host (name)
  "Point El Yayster at host NAME from `yayster-hosts'.
Sets both the endpoint and that host's default model."
  (interactive
   (list (completing-read "Host: " (mapcar #'car yayster-hosts) nil t)))
  (let ((h (assoc name yayster-hosts)))
    (unless h (user-error "Unknown host: %s" name))
    (setq yayster-endpoint (nth 1 h)
          yayster-model    (nth 2 h))
    (yayster--fetch-context-size)
    (unless noninteractive
      (message "El Yayster -> %s (%s, ctx %s)"
               name yayster-model yayster-context-size))
    name))

(defvar yayster--log-buffer "*yayster*"
  "Buffer where the operator's thinking and actions stream.")

;;; ─────────────────────────────────────────────────────────────
;;; 1. CAPABILITIES  (the agent's hands)
;;; ─────────────────────────────────────────────────────────────

(cl-defstruct (yayster-cap (:constructor yayster-cap-make))
  name doc mutating fn)

(defvar yayster--caps (make-hash-table :test 'equal)
  "Registry of capability-name -> `yayster-cap'.")

(defun yayster-register (cap)
  "Add CAP to the registry."
  (puthash (yayster-cap-name cap) cap yayster--caps))

(defmacro yayster-defcap (name arglist &rest body)
  "Define capability NAME with ARGLIST (one plist arg).
Leading keywords :doc :mutating are consumed; the rest is the body."
  (declare (indent 2))
  (let ((doc "") (mut nil))
    (while (keywordp (car body))
      (let ((k (pop body)) (v (pop body)))
        (pcase k (:doc (setq doc v)) (:mutating (setq mut v)))))
    `(yayster-register
      (yayster-cap-make
       :name ,name :doc ,doc :mutating ,mut
       :fn (lambda ,arglist (ignore ,@arglist) ,@body)))))

;;; ---- Read-only (auto-approved) ----

(yayster-defcap "read_buffer" (a)
  :doc "Return the text of buffer :name (defaults to current)."
  (let ((b (get-buffer (or (plist-get a :name) (buffer-name)))))
    (if b (with-current-buffer b
            (buffer-substring-no-properties (point-min) (point-max)))
      (format "no such buffer: %s" (plist-get a :name)))))

(yayster-defcap "list_buffers" (a)
  :doc "List live buffer names with their major modes."
  (mapconcat (lambda (b) (format "%s [%s]" (buffer-name b)
                                 (buffer-local-value 'major-mode b)))
             (buffer-list) "\n"))

(yayster-defcap "apropos" (a)
  :doc "List function symbols matching :pattern — lets you DISCOVER your own tools."
  (let ((syms (apropos-internal (or (plist-get a :pattern) "") #'fboundp)))
    (mapconcat #'symbol-name (seq-take syms 60) "\n")))

(yayster-defcap "describe" (a)
  :doc "Return the docstring of function :symbol."
  (let ((s (intern-soft (or (plist-get a :symbol) ""))))
    (or (and s (documentation s)) "no docs")))

;;; ---- Mutating (always gated) ----

(yayster-defcap "eval_elisp" (a)
  :doc "Evaluate an Emacs Lisp expression :code and return its value."
  :mutating t
  (condition-case err
      (format "%S" (eval (car (read-from-string (plist-get a :code))) t))
    (error (format "ERROR: %S" err))))

(yayster-defcap "write_buffer" (a)
  :doc "Replace buffer :name contents with :text (previewed before applying)."
  :mutating t
  (with-current-buffer (get-buffer-create (plist-get a :name))
    (erase-buffer) (insert (or (plist-get a :text) "")) "written"))

(yayster-defcap "run_command" (a)
  :doc "Run shell command :cmd; return stdout+stderr."
  :mutating t
  (let ((cmd (plist-get a :cmd)))
    (unless (and (stringp cmd) (not (string-empty-p (string-trim cmd))))
      (error "run_command: missing or empty :cmd"))
    (let ((out (with-timeout (yayster-command-timeout
                              (error "run_command: timed out after %s s"
                                     yayster-command-timeout))
                 (shell-command-to-string cmd)))
          (limit yayster-command-max-bytes))
      (if (and (stringp out) (> (string-bytes out) limit))
          (concat (substring out 0 (min (length out) limit))
                  "\n… [truncated]")
        out))))

;;; ─────────────────────────────────────────────────────────────
;;; 2. PERMISSION GATE  (agent drafts, human commits)
;;; ─────────────────────────────────────────────────────────────

(defvar yayster--pending-detail nil
  "Full text of the action currently awaiting approval, for dialog/buffer display.")

(defun yayster--pp-args (args)
  "Render ARGS plist for human review, surfacing the important field."
  (cond
   ((plist-get args :cmd)    (concat "$ " (plist-get args :cmd)))
   ((plist-get args :code)   (plist-get args :code))
   ((plist-get args :text)   (concat "text:\n" (plist-get args :text)))
   (t (format "%S" args))))

(defvar yayster--yolo nil
  "When non-nil, mutating capabilities auto-approve without prompting.
Session-scoped: stays set across turns until `\\[yayster-safety-on]'.")

(defun yayster-safety-on ()
  "Re-arm the permission gate: turn OFF YOLO auto-approval."
  (interactive)
  (setq yayster--yolo nil)
  (unless noninteractive
    (message "El Yayster: safety re-armed — mutating actions will ask again.")))

(defun yayster--show-permission (text)
  "Show TEXT in *yayster-permission* so the full payload is inspectable."
  (unless noninteractive
    (with-current-buffer (get-buffer-create "*yayster-permission*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (display-buffer (current-buffer))))))

(defun yayster--confirm (prompt)
  "Approve or deny the pending action described by PROMPT.
Return non-nil to allow.
Details come from `yayster--pending-detail'.  On a graphical frame
\(when `yayster-use-dialog') this pops a GUI dialog box with
Allow / YOLO / Deny; otherwise it shows the action in *yayster-permission*
and asks in the minibuffer.
The permission buffer is filled with the full payload before the prompt
so you can review exactly what will execute.
YOLO approves this action AND sets `yayster--yolo' so further
mutating actions auto-approve until you run `\\[yayster-safety-on]'.
Closing, cancelling, or C-g counts as a denial."
  (let* ((detail yayster--pending-detail)
         (full (if detail (concat prompt "\n\n" detail) prompt)))
    (when detail (yayster--show-permission full))
    (let ((choice
           (if (and yayster-use-dialog (display-graphic-p) (not noninteractive))
               (condition-case nil
                   (let ((last-nonmenu-event nil))  ; force a real dialog, not an echo
                     (x-popup-dialog
                      t (list full
                              '("Allow" . allow)
                              '("YOLO — stop asking" . yolo)
                              '("Deny" . deny))))
                 (quit 'deny))                        ; ESC / close = deny
             (if noninteractive 'deny
               (condition-case nil
                   (pcase (read-char-choice
                           (concat prompt "  [y]es  [n]o  [!]YOLO: ") '(?y ?n ?!))
                     (?y 'allow) (?! 'yolo) (_ 'deny))
                 (quit 'deny))))))
      (pcase choice
        ('yolo (setq yayster--yolo t)
               (yayster--log
                ";; ⚡ YOLO engaged — auto-approving mutating actions. M-x yayster-safety-on to re-arm.")
               t)
        ('allow t)
        (_ nil)))))

(defun yayster--approved-p (cap args)
  "Return non-nil if executing CAP with ARGS is permitted.
The confirm prompt contains the full argument payload — no truncation."
  (cond
   ((and (not (yayster-cap-mutating cap)) yayster-auto-approve-readonly) t)
   (yayster--yolo t)
   (t (let* ((payload (yayster--pp-args args))
             (yayster--pending-detail
              (format "Capability: %s\n%s\n\n%s"
                      (yayster-cap-name cap) (yayster-cap-doc cap) payload))
             (prompt (format "Allow %s?\n%s" (yayster-cap-name cap) payload)))
        (funcall yayster-confirm-function prompt)))))

(defvar yayster--origin-buffer nil
  "Buffer that was current when `yayster-step' started this turn.")
(defvar yayster--origin-directory nil
  "default-directory when `yayster-step' started this turn.")

(defun yayster--with-origin (fn)
  "Call FN with the turn's origin buffer and default-directory current.
If the origin buffer is dead, FN still runs with the saved directory bound."
  (let ((dir (or yayster--origin-directory default-directory))
        (buf yayster--origin-buffer))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (let ((default-directory dir))
            (funcall fn)))
      (let ((default-directory dir))
        (funcall fn)))))

(defun yayster--execute (name args)
  "Look up capability NAME, gate it, run it, return a result string.
Runs in the origin buffer/directory captured at the start of the turn so
tools see the environment advertised in the situating prompt."
  (let ((cap (gethash name yayster--caps)))
    (cond
     ((null cap) (format "ERROR: unknown capability %s" name))
     ((not (yayster--approved-p cap args)) "DENIED by user")
     (t (condition-case err
            (yayster--with-origin
             (lambda () (funcall (yayster-cap-fn cap) args)))
          (error (format "ERROR: %S" err)))))))

;;; ─────────────────────────────────────────────────────────────
;;; 3. SITUATING PROMPT
;;; ─────────────────────────────────────────────────────────────

(defun yayster--tool-manifest ()
  "Render the capability registry for the system prompt."
  (let (lines)
    (maphash (lambda (name cap)
               (push (format "- %s%s : %s" name
                             (if (yayster-cap-mutating cap) " (asks permission)" "")
                             (yayster-cap-doc cap))
                     lines))
             yayster--caps)
    (string-join (sort lines #'string<) "\n")))

(defun yayster--situate ()
  "Build the system prompt: identity + live environment + tools + protocol."
  (format "You are El Yayster, a resident agent living inside a running Emacs (user %s).
You are not a chatbot; you operate this editor through capabilities.

CURRENT ENVIRONMENT
- open buffers: %s
- current buffer: %s (%s)
- default-directory: %s

CAPABILITIES
%s

PROTOCOL
To act, reply with EXACTLY these two lines at the start of their own lines:
ACTION: <capability-name>
ARGS: <one-line JSON object>
Then stop; you will receive a line beginning RESULT:.
When you are done, reply with a single line:
FINAL: <your answer>
A FINAL: line ends the turn and is never executed, even if ACTION/ARGS also appear.
Keep ARGS on one line as valid JSON (e.g. {\"pattern\": \"org-\"}). Empty {} is valid.
Mutating capabilities may return DENIED if the human declines."
          (user-login-name)
          (mapconcat #'buffer-name (seq-take (buffer-list) 12) ", ")
          (buffer-name) major-mode default-directory
          (yayster--tool-manifest)))

;;; ─────────────────────────────────────────────────────────────
;;; 4. TRANSPORT + AGENT LOOP
;;; ─────────────────────────────────────────────────────────────

(defun yayster--msgs->json (messages)
  "Convert internal MESSAGES (plists) to a JSON payload string."
  (let ((arr (mapcar (lambda (m)
                       `(("role" . ,(plist-get m :role))
                         ("content" . ,(plist-get m :content))))
                     messages)))
    (json-encode `(("model" . ,yayster-model)
                   ("messages" . ,(vconcat arr))
                   ("stream" . :json-false)))))

(defun yayster--extract (code raw)
  "Turn curl exit CODE + RAW response body into a result plist.
Returns (:content STRING :usage (:prompt P :completion C :total T)) — :usage
is nil if the server did not report token counts."
  (if (/= code 0)
      (list :content (format "TRANSPORT-ERROR: curl exit %s" code) :usage nil)
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-array-type 'vector)
               (resp (json-read-from-string raw))
               (choices (alist-get 'choices resp))
               (msg (and (> (length choices) 0)
                         (alist-get 'message (aref choices 0))))
               (usage (alist-get 'usage resp)))
          (list :content (or (alist-get 'content msg) (format "EMPTY: %s" raw))
                :usage (when usage
                         (list :prompt     (or (alist-get 'prompt_tokens usage) 0)
                               :completion (or (alist-get 'completion_tokens usage) 0)
                               :total      (or (alist-get 'total_tokens usage) 0)))))
      (error (list :content (format "PARSE-ERROR: %S :: %s" err
                                    (substring raw 0 (min (length raw) 300)))
                   :usage nil)))))

(defvar yayster--busy nil
  "Non-nil while a turn is in flight, to prevent overlapping runs.")
(defvar yayster--proc nil
  "Live curl process for the in-flight turn, or nil.")
(defvar yayster--payload-file nil
  "Temp JSON payload for the in-flight curl, or nil.")
(defvar yayster--key-file nil
  "Temp Authorization header file for the in-flight curl, or nil.")
(defvar yayster--aborting nil
  "Non-nil while `yayster-abort' is tearing down the turn.")

(defun yayster--cleanup-transport ()
  "Unlink curl temp files and drop the process handle.  Safe to call twice."
  (when yayster--payload-file
    (ignore-errors (delete-file yayster--payload-file))
    (setq yayster--payload-file nil))
  (when yayster--key-file
    (ignore-errors (delete-file yayster--key-file))
    (setq yayster--key-file nil))
  (setq yayster--proc nil))

(defun yayster-abort ()
  "Kill the in-flight curl process, unlink temps, and end the turn."
  (interactive)
  (setq yayster--aborting t)
  (when (and yayster--proc (process-live-p yayster--proc))
    (ignore-errors (delete-process yayster--proc)))
  (yayster--cleanup-transport)
  (when yayster--busy
    (yayster--finish "(aborted)"))
  (setq yayster--aborting nil)
  (unless noninteractive
    (message "El Yayster: aborted.")))

(defun yayster--llm-async (messages callback)
  "POST MESSAGES via a curl subprocess; call CALLBACK with a result plist.
The plist is (:content STRING :usage ...) — see `yayster--extract'.
Non-blocking: returns immediately, Emacs stays responsive.
Bearer tokens go in a 0600 header file (`curl -H @FILE'), never on argv."
  (let* ((payload (make-temp-file "yy-req" nil ".json"))
         (keyfile nil)
         (outbuf (generate-new-buffer " *yayster-curl*"))
         (args (list "-s" "--max-time" (number-to-string yayster-timeout)
                     yayster-endpoint
                     "-H" "Content-Type: application/json"))
         (started nil))
    (unwind-protect
        (progn
          (with-temp-file payload (insert (yayster--msgs->json messages)))
          (when yayster-api-key
            (setq keyfile (make-temp-file "yy-key" nil ".hdr"))
            (with-temp-file keyfile
              (insert "Authorization: Bearer " yayster-api-key "\n"))
            (set-file-modes keyfile #o600)
            (setq args (append args (list "-H" (concat "@" keyfile)))))
          (setq args (append args (list "--data" (concat "@" payload))))
          (setq yayster--payload-file payload
                yayster--key-file keyfile)
          (setq yayster--proc
                (make-process
                 :name "yayster-curl"
                 :buffer outbuf
                 :command (cons "curl" args)
                 :noquery t
                 :connection-type 'pipe
                 :sentinel
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (let ((code (process-exit-status proc))
                           (raw (if (buffer-live-p outbuf)
                                    (with-current-buffer outbuf (buffer-string))
                                  "")))
                       (yayster--cleanup-transport)
                       (ignore-errors
                         (when (buffer-live-p outbuf) (kill-buffer outbuf)))
                       (cond
                        (yayster--aborting
                         (yayster--finish "(aborted)"))
                        (t
                         (condition-case err
                             (funcall callback (yayster--extract code raw))
                           (error
                            (yayster--finish
                             (format "SENTINEL-ERROR: %S" err)))))))))))
          (setq started t))
      (unless started
        (yayster--cleanup-transport)
        (ignore-errors (when (buffer-live-p outbuf) (kill-buffer outbuf)))
        (when yayster--busy
          (yayster--finish "TRANSPORT-ERROR: failed to start curl"))))))

(defun yayster--parse-reply (text)
  "Parse model TEXT into a protocol event.
Return (final . ANSWER) if a line starts with FINAL: (FINAL wins).
Return (action NAME . PLIST) if ACTION: and ARGS: start their own lines
and ARGS is valid JSON.  Empty {} is a valid empty plist.
Return nil on chatter, missing ARGS, or malformed JSON.
ACTION/ARGS substrings that are not at line start are ignored."
  (let ((src (concat "\n" (or text ""))))
    (cond
     ((string-match "\n[ \t]*FINAL:[ \t]*\\(.*\\)" src)
      (cons 'final (string-trim (match-string 1 src))))
     ((string-match "\n[ \t]*ACTION:[ \t]*\\([^\n]+\\)" src)
      (let* ((name (string-trim (match-string 1 src)))
             (rest (substring src (match-end 0))))
        (when (string-match "\\`\n+[ \t]*ARGS:[ \t]*\\([^\n]*\\)" rest)
          (let ((raw (string-trim (match-string 1 rest))))
            (cond
             ((string-empty-p raw) nil)
             ((string= raw "{}") (cons 'action (cons name nil)))
             (t (condition-case nil
                    (let ((json-object-type 'plist) (json-key-type 'keyword))
                      (cons 'action (cons name (json-read-from-string raw))))
                  (error nil))))))))
     (t nil))))

(defun yayster--headerline ()
  "Status line for the *yayster* buffer: model, context occupancy, token counts."
  (let* ((ctx  (max 1 yayster-context-size))
         (used yayster--last-prompt-tokens)
         (pct  (round (* 100.0 (/ (float used) ctx)))))
    (format " el yayster  %s  ctx %s/%s (%d%%)  turn %s tok  session %s tok%s"
            yayster-model used ctx pct
            (+ yayster--turn-prompt yayster--turn-completion)
            yayster--session-tokens
            (if yayster--yolo "  ⚡YOLO" ""))))

(defun yayster--log (s)
  "Append S to the *yayster* thinking buffer (and echo in batch)."
  (if noninteractive
      (princ (concat s "\n"))
    (with-current-buffer (get-buffer-create yayster--log-buffer)
      (unless header-line-format
        (setq header-line-format '(:eval (yayster--headerline))))
      (goto-char (point-max)) (insert s "\n\n")
      (let ((w (get-buffer-window (current-buffer))))
        (if w (set-window-point w (point-max))
          (display-buffer (current-buffer)))))))

(defun yayster--finish (out)
  "End the current turn: log OUT + token summary, echo it, clear the busy flag.
Idempotent: a second call while idle is a no-op (returns OUT)."
  (if (not yayster--busy)
      out
    (setq yayster--busy nil)
    (yayster--log (concat "== " out))
    (yayster--log
     (format ";; tokens: %d prompt + %d completion = %d over %d call%s  (session %d)"
             yayster--turn-prompt yayster--turn-completion
             (+ yayster--turn-prompt yayster--turn-completion)
             yayster--turn-calls
             (if (= yayster--turn-calls 1) "" "s")
             yayster--session-tokens))
    (unless noninteractive (message "El Yayster: %s" out))
    out))

;;;###autoload
(defun yayster-step (user-input)
  "Ask the resident operator USER-INPUT.  Runs ASYNCHRONOUSLY.
Returns immediately; Emacs stays fully usable while it works.
Progress and the final answer stream into the *yayster* buffer, and the
final answer is also echoed in the minibuffer.
Overlapping turns are refused in interactive and batch sessions.
C-g on a permission prompt is deny.  `\\[yayster-abort]' kills a hung turn."
  (interactive "sEl Yayster: ")
  (when yayster--busy
    (user-error "El Yayster is still working on the previous request — see *yayster*. M-x yayster-abort to interrupt."))
  (setq yayster--aborting nil
        yayster--busy t
        yayster--turn-prompt 0
        yayster--turn-completion 0
        yayster--turn-calls 0
        yayster--origin-buffer (current-buffer)
        yayster--origin-directory default-directory)
  (let ((started nil)
        (msgs nil)
        (steps 0))
    (unwind-protect
        (progn
          (setq msgs (list (list :role "system" :content (yayster--situate))
                           (list :role "user"   :content user-input)))
          (yayster--log (concat "USER: " user-input))
          (cl-labels
              ((drive ()
                 (setq steps (1+ steps))
                 (if (> steps yayster-max-steps)
                     (yayster--finish "(step limit reached)")
                   (yayster--llm-async
                    msgs
                    (lambda (res)
                      (let ((reply (plist-get res :content))
                            (usage (plist-get res :usage)))
                        (when usage
                          (setq yayster--turn-prompt
                                (+ yayster--turn-prompt
                                   (or (plist-get usage :prompt) 0))
                                yayster--turn-completion
                                (+ yayster--turn-completion
                                   (or (plist-get usage :completion) 0))
                                yayster--turn-calls
                                (1+ yayster--turn-calls)
                                yayster--last-prompt-tokens
                                (or (plist-get usage :prompt) 0)
                                yayster--session-tokens
                                (+ yayster--session-tokens
                                   (or (plist-get usage :total) 0))))
                        (setq msgs (append msgs (list (list :role "assistant"
                                                            :content reply))))
                        (yayster--log (format "[%d] %s" steps reply))
                        (let ((ev (yayster--parse-reply reply)))
                          (cond
                           ((eq (car-safe ev) 'final)
                            (yayster--finish (cdr ev)))
                           ((eq (car-safe ev) 'action)
                            (let ((result (yayster--execute (cadr ev)
                                                                  (cddr ev))))
                              (yayster--log (concat "→ RESULT: " result))
                              (setq msgs
                                    (append msgs
                                            (list (list :role "user"
                                                        :content (concat "RESULT: " result)))))
                              (drive)))
                           (t (yayster--finish reply))))))))))
            (drive))
          (setq started t)
          (unless noninteractive (message "El Yayster working… (see *yayster*)"))
          nil)
      (unless started
        (yayster--cleanup-transport)
        (when yayster--busy
          (yayster--finish "ERROR: failed to start turn"))))))

;;; ─────────────────────────────────────────────────────────────
;;; 5. AWAKEN
;;; ─────────────────────────────────────────────────────────────

;;;###autoload
(defun yayster-awaken ()
  "Bring the resident operator online.  Call from init.el."
  (interactive)
  (yayster--fetch-context-size)
  (yayster--log
   (format ";; el yayster awake — Emacs %s, %d capabilities, model %s @ %s (ctx %s)\n;; The interface is alive."
           emacs-version (hash-table-count yayster--caps)
           yayster-model yayster-endpoint
           yayster-context-size))
  (unless noninteractive
    (message "El Yayster awake. M-x yayster-step to talk. M-x yayster-use-host to switch GPU host.")))

(provide 'yayster)
;;; yayster.el ends here
