;;; yayster-tests.el --- ERT tests for yayster -*- lexical-binding: t; -*-

(require 'ert)
(require 'yayster)

(ert-deftest yayster-parse-final-wins ()
  "A FINAL: line ends the turn even if ACTION/ARGS are also present."
  (should (equal (yayster--parse-reply
                  "FINAL: done\nACTION: run_command\nARGS: {\"cmd\":\"rm -rf /\"}")
                 '(final . "done"))))

(ert-deftest yayster-parse-action-line-start ()
  (let ((ev (yayster--parse-reply "ACTION: apropos\nARGS: {\"pattern\":\"org-\"}")))
    (should (eq (car ev) 'action))
    (should (equal (cadr ev) "apropos"))
    (should (equal (plist-get (cddr ev) :pattern) "org-"))))

(ert-deftest yayster-parse-malformed-args-not-a-call ()
  (should (null (yayster--parse-reply "ACTION: eval_elisp\nARGS: not-json"))))

(ert-deftest yayster-parse-missing-args-not-a-call ()
  (should (null (yayster--parse-reply "ACTION: eval_elisp\nno args here"))))

(ert-deftest yayster-parse-empty-object-ok ()
  (let ((ev (yayster--parse-reply "ACTION: list_buffers\nARGS: {}")))
    (should (eq (car ev) 'action))
    (should (equal (cadr ev) "list_buffers"))
    (should (null (cddr ev)))))

(ert-deftest yayster-parse-ignores-mid-line-action ()
  (should (null (yayster--parse-reply
                 "I might ACTION: run_command later\nARGS: {\"cmd\":\"true\"}"))))

(ert-deftest yayster-run-command-rejects-empty ()
  (let ((yayster--yolo t)
        (yayster-confirm-function (lambda (&rest _) t)))
    (should (string-match-p "ERROR:" (yayster--execute "run_command" nil)))
    (should (string-match-p "ERROR:" (yayster--execute "run_command" '(:cmd ""))))))

(ert-deftest yayster-readonly-auto-approves ()
  (let ((called nil)
        (yayster--yolo nil)
        (yayster-auto-approve-readonly t)
        (yayster-confirm-function
         (lambda (&rest _) (setq called t) nil)))
    (yayster--execute "list_buffers" nil)
    (should (not called))))

(ert-deftest yayster-mutating-prompt-includes-payload ()
  (let ((prompt nil)
        (yayster--yolo nil)
        (yayster-auto-approve-readonly t)
        (orig yayster-confirm-function))
    (unwind-protect
        (progn
          (setq yayster-confirm-function
                (lambda (p) (setq prompt p) nil))
          (should (equal (yayster--execute "eval_elisp" '(:code "(+ 1 2)"))
                         "DENIED by user"))
          (should (stringp prompt))
          (should (string-match-p "eval_elisp" prompt))
          (should (string-match-p (regexp-quote "(+ 1 2)") prompt)))
      (setq yayster-confirm-function orig))))

(ert-deftest yayster-confirm-prompt-is-not-truncated ()
  "A payload longer than 4k is still shown in full on the confirm prompt."
  (let* ((code (concat "(progn " (make-string 5000 ?x) ")"))
         (prompt nil)
         (yayster--yolo nil)
         (orig yayster-confirm-function))
    (unwind-protect
        (progn
          (setq yayster-confirm-function
                (lambda (p) (setq prompt p) nil))
          (yayster--execute "eval_elisp" (list :code code))
          (should (stringp prompt))
          (should (> (length prompt) 5000))
          (should (string-match-p (regexp-quote code) prompt))
          (should-not (string-match-p "truncated" prompt)))
      (setq yayster-confirm-function orig))))

(ert-deftest yayster-finish-is-idempotent ()
  (let ((yayster--busy t)
        (yayster--turn-prompt 0)
        (yayster--turn-completion 0)
        (yayster--turn-calls 1)
        (yayster--session-tokens 0))
    (should (equal (yayster--finish "a") "a"))
    (should (null yayster--busy))
    (should (equal (yayster--finish "b") "b"))
    (should (null yayster--busy))))

(ert-deftest yayster-origin-directory-used-when-buffer-dead ()
  (let* ((dir (temporary-file-directory))
         (yayster--origin-buffer (get-buffer-create " *yy-dead-origin*"))
         (yayster--origin-directory dir)
         got)
    (kill-buffer yayster--origin-buffer)
    (yayster--with-origin (lambda () (setq got default-directory)))
    (should (equal got dir))))

(provide 'yayster-tests)
;;; yayster-tests.el ends here
