;;;; $Id$
;;;; $Source$

;;;; specbot.lisp - an example IRC bot for cl-irc

;;; specbot is an example IRC bot for cl-irc. It runs on
;;; irc.freenode.net in the channels #lisp, #scheme and #clhs
;;; (preferred for testing). It responds to queries of its various
;;; databases, which right now include "clhs" and "r5rs".

;;; You will need to load and populate the tables for both the clhs
;;; and r5rs lookup packages; currently these are available in
;;; lisppaste CVS.

;;; To use it, load the cl-irc system, load specbot.lisp, and
;;; invoke (specbot:start-specbot "desirednickname" "desiredserver"
;;; "#channel1" "#channel2" "#channel3" ...)

(defpackage :specbot (:use :common-lisp :irc) (:export :start-specbot
                                                       :shut-up
                                                       :un-shut-up))
(in-package :specbot)

(defvar *connection*)
(defvar *nickname* "")

(defun shut-up ()
  (setf (irc:client-stream *connection*) (make-broadcast-stream)))

(defun un-shut-up ()
  (setf (irc:client-stream *connection*) *trace-output*))

(defmacro aif (test conseq &optional (else nil))
  `(let ((it ,test))
     (if it ,conseq
       (symbol-macrolet ((it ,test))
         ,else))))

(defun clhs-lookup (str)
  (aif (and (find-package :clhs-lookup)
            (funcall (intern "SPEC-LOOKUP" :clhs-lookup)
                     str))
       it
       (format nil "Nothing was found for: ~A" str)))

(defun r5rs-lookup (str)
  (aif (and (find-package :r5rs-lookup)
            (funcall (intern "SYMBOL-LOOKUP" :r5rs-lookup)
                     str))
       it
       (format nil "Nothing was found for: ~A" str)))

(defparameter *spec-providers*
  '((clhs-lookup "clhs" "The Comon Lisp HyperSpec")
    (r5rs-lookup "r5rs" "The Revised 5th Ed. Report on the Algorithmic Language Scheme")))

(defun valid-message (string prefix &key space-allowed)
  (if (eql (search prefix string :test #'char-equal) 0)
      (and (or space-allowed
               (not (find #\space string :start (length prefix))))
           (length prefix))
      nil))

(defun strip-address (string &key (address *nickname*) (final nil))
  (loop for i in (list (format nil "~A " address)
                       (format nil "~A: " address)
                       (format nil "~A:" address)
                       (format nil "~A, " address))
        do (aif (valid-message string i :space-allowed (not final))
                (return-from strip-address (subseq string it))))
  (and (not final) string))

(defun msg-hook (message)
  (let ((destination (if (string-equal (first (arguments message)) *nickname*)
                         (source message)
                         (first (arguments message))))
        (to-lookup (strip-address (trailing-argument message))))
    (if (member to-lookup '("help" "help?") :test #'string-equal)
        (progn
          (privmsg *connection* destination
                   (format nil "To use the ~A bot, say something like \"database term\", where database is one of (~{~S~^, ~}) and term is the desired lookup."
                           *nickname*
                           (mapcar #'second *spec-providers*)))
          (privmsg *connection* destination
                   (format nil "The available databases are: ~{~{~*~S, ~A~}~^; ~}"
                           *spec-providers*)))
        (loop for type in *spec-providers*
              do
              (aif (strip-address to-lookup :address (second type) :final t)
                   (privmsg *connection* destination (funcall (first type) it)))))))
  
(defun start-specbot (nick server &rest channels)
  (setf *nickname* nick)
  (setf *connection* (connect :nickname *nickname* :server server))
  (mapcar #'(lambda (channel) (join *connection* channel)) channels)
  (add-hook *connection* 'irc::irc-privmsg-message 'msg-hook)
  #+(or sbcl
        openmcl)
  (start-background-message-handler *connection*)
  #-(or sbcl
        openmcl)
  (read-message-loop *connection*))

(defun shuffle-hooks ()
  (irc::remove-hooks *connection* 'irc::irc-privmsg-message)
  (add-hook *connection* 'irc::irc-privmsg-message 'msg-hook))