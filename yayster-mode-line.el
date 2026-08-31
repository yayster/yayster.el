;;; yayster-mode-line.el --- El Yayster host/model light in the mode line -*- lexical-binding: t -*-
;; Event-driven host/model indicator; pulses while a turn is in flight.
(require 'cl-lib)

;; Forward declarations — these live in yayster.el (required at load).
(defvar yayster-endpoint)
(defvar yayster-model)
(defvar yayster-hosts)
(defvar yayster--busy)

(defvar mode-line-yayster ""
  "El Yayster host/model indicator for the mode line.")
(put 'mode-line-yayster 'risky-local-variable t)

(defun yayster-mode-host-name ()
  "Short host name whose endpoint matches El Yayster, else \"custom\"."
  (let ((match (cl-find-if (lambda (h) (string= (nth 1 h) yayster-endpoint))
                           (bound-and-true-p yayster-hosts))))
    (or (and match (car match)) "custom")))

(defun yayster-mode--status ()
  "A short string describing the current El Yayster state."
  (if (not (boundp 'yayster-model))
      ""
    (let ((host (yayster-mode-host-name))
          (busy (and (boundp 'yayster--busy) yayster--busy)))
      (format " \u232c %s %s%s" host yayster-model
              (if busy " \u25d0" "")))))

(defun yayster-mode-refresh (&rest _)
  "Recompute `mode-line-yayster' and repaint the mode lines.
Accepts and ignores any args so it can serve as :after advice."
  (setq mode-line-yayster (yayster-mode--status))
  (force-mode-line-update t))

(defvar yayster-mode--advised
  '(yayster-step yayster--finish
    yayster-use-host yayster-safety-on
    yayster-abort yayster--llm-async)
  "Functions whose completion should refresh the indicator.")

(defun yayster-mode-install ()
  "Put `mode-line-yayster' in `mode-line-format' and keep it fresh.
Refreshes on real state changes (turn start/finish, host switch, safety
re-arm) via advice — no fake hooks, no polling."
  (unless (member 'mode-line-yayster mode-line-format)
    (if (member 'mode-line-position mode-line-format)
        (let ((i (cl-position 'mode-line-position mode-line-format)))
          (setf mode-line-format
                (append (seq-take mode-line-format (1+ i))
                        (list 'mode-line-yayster)
                        (seq-drop mode-line-format (1+ i)))))
      (setq mode-line-format
            (append mode-line-format (list 'mode-line-yayster)))))
  (dolist (fn yayster-mode--advised)
    (when (fboundp fn)
      (advice-add fn :after #'yayster-mode-refresh)))
  (yayster-mode-refresh))

(defun yayster-mode-uninstall ()
  "Remove the indicator and its advice."
  (interactive)
  (dolist (fn yayster-mode--advised)
    (when (fboundp fn)
      (advice-remove fn #'yayster-mode-refresh)))
  (setq mode-line-format (delq 'mode-line-yayster mode-line-format))
  (force-mode-line-update t))

(when (require 'yayster nil t)
  (yayster-mode-install))

(provide 'yayster-mode-line)
;;; yayster-mode-line.el ends here
