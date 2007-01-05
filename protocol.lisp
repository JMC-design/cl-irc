;;;; $Id$
;;;; $URL$

;;;; See LICENSE for licensing information.

(in-package :irc)

;;
;; Condition
;;

(define-condition no-such-reply ()
  ((reply-number
    :reader reply-number
    :initarg :reply-number))
  (:report (lambda (condition stream)
             (format stream "No such reply ~A." (reply-number condition)))))



;;
;; Modes
;;

;; generic abstract mode class

(defclass irc-mode ()
  ((value
    :initarg :value
    :accessor value
    :initform nil)
   (value-type
    :initarg :value-type
    :accessor value-type
    :documentation "The framework sets this to `:user' or `:non-user'.
Essentially, if it's `:user', the value(s) held must be derived from the
user class.")))

(defgeneric set-mode-value (mode-object value))
(defgeneric unset-mode-value (mode-object value))
(defgeneric reset-mode-value (mode-object))
(defgeneric has-value-p (mode-object value &key key test))

(defmethod reset-mode-value ((mode irc-mode))
  (setf (value mode) nil))


;; mode class for holding boolean values

(defclass boolean-value-mode (irc-mode) ())

(defmethod set-mode-value ((mode boolean-value-mode) value)
  (declare (ignore value))
  (setf (value mode) t))

(defmethod unset-mode-value ((mode boolean-value-mode) value)
  (declare (ignore value))
  (setf (value mode) nil))

(defmethod has-value-p ((mode boolean-value-mode) value
                        &key key test)
  (declare (ignore value key test))
  (value mode))

;; mode class for holding single values

(defclass single-value-mode (irc-mode) ())

(defmethod set-mode-value ((mode single-value-mode) value)
  (setf (value mode) value))

(defmethod unset-mode-value ((mode single-value-mode) value)
  (when (or (null value)
            (equal value (value mode)))
    (setf (value mode) nil)))

(defmethod has-value-p ((mode single-value-mode) value
                        &key (key #'identity) (test #'equal))
  (funcall test
           value
           (funcall key (value mode))))


;; mode class for holding lists of values

(defclass list-value-mode (irc-mode) ())

(defmethod set-mode-value ((mode list-value-mode) value)
  (push value (value mode)))

(defmethod unset-mode-value ((mode list-value-mode) value)
  (setf (value mode)
        (remove value (value mode))))

(defmethod has-value-p ((mode list-value-mode) value
                        &key (key #'identity) (test #'equal))
  (let ((key-value (funcall key value)))
    (some #'(lambda (x)
              (funcall test
                       key-value
                       (funcall key x)))
          (value mode))))

;;
;; Connection
;;


(defclass connection ()
  ((user
    :initarg :user
    :accessor user)
   (password
    :initarg :password
    :accessor password
    :initform nil)
   (server-name
    :initarg :server-name
    :accessor server-name
    :initform "Unknown server")
   (server-port
    :initarg :server-port
    :accessor server-port
    :initform *default-irc-server-port*)
   (socket
    :initarg :socket
    :documentation "Slot to store socket (for internal use only).")
   (network-stream
    :initarg :network-stream
    :accessor network-stream
    :documentation "Stream used to talk binary to the IRC server.")
   (output-stream
    :initarg :output-stream
    :accessor output-stream
    :documentation "Stream used to send messages to the IRC server")
   (server-capabilities
    :initform *default-isupport-values*
    :accessor server-capabilities
    :documentation "Assoc array for rpl_isupport message;
see http://www.irc.org/tech_docs/draft-brocklesby-irc-isupport-03.txt")
   (client-stream
    :initarg :client-stream
    :accessor client-stream
    :initform t
    :documentation "Messages coming back from the server is sent to
this stream.")
   (channels
    :initarg :channels
    :accessor channels
    :initform (make-hash-table :test #'equal))
   (hooks
    :initarg :hooks
    :accessor hooks
    :initform (make-hash-table :test #'equal))
   (channel-mode-descriptions
    :initarg :channel-mode-descriptions
    :accessor channel-mode-descriptions
    :initform (chanmode-descs-from-isupport *default-isupport-values*)
    :documentation
    "Describes the modes an application intends to register with channels.")
   (nick-prefixes
    :initarg :nick-prefixes
    :accessor nick-prefixes
    :initform (nick-prefixes-from-isupport *default-isupport-values*))
   (user-mode-destriptions
    :initarg :user-mode-descriptions
    :accessor user-mode-descriptions
    :initform (mapcar #'(lambda (x)
                          (make-mode-description :char (car x)
                                                 :symbol (cdr x)))
                      *char-to-user-modes-map*)
    :documentation
    "Describes the modes an application intends to register with channels.")
   (users
    :initarg :users
    :accessor users
    :initform (make-hash-table :test #'equal))))

(defmethod print-object ((object connection) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (princ (server-name object) stream)))

(defgeneric add-default-hooks (connection))
(defgeneric client-raw-log (connection message))
(defgeneric connectedp (connection))
(defgeneric read-message (connection))
(defgeneric start-process (function name))
(defgeneric read-irc-message (connection))
(defgeneric send-irc-message (connection command &rest arguments))
(defgeneric get-hooks (connection class))
(defgeneric add-hook (connection class hook))
(defgeneric remove-hook (connection class hook))
(defgeneric remove-hooks (connection class))
(defgeneric remove-all-hooks (connection))

(defgeneric case-map-name (connection))
(defgeneric re-apply-case-mapping (connection))

(defun make-connection (&key (connection-type 'connection)
                             (user nil)
                             (password nil)
                             (server-name "")
                             (server-port nil)
                             (socket nil)
                             (network-stream nil)
                             (outgoing-external-format *default-outgoing-external-format*)
                             (client-stream t)
                             (hooks nil))
  (let* ((output-stream (flexi-streams:make-flexi-stream
                         network-stream
                         :element-type 'character
                         :external-format (external-format-fixup outgoing-external-format)))
         (connection (make-instance connection-type
                                   :user user
                                   :password password
                                   :server-name server-name
                                   :server-port server-port
                                   :socket socket
                                   :network-stream network-stream
                                   :output-stream output-stream
                                   :client-stream client-stream)))
    (dolist (hook hooks)
      (add-hook connection (car hook) (cadr hook)))
    connection))

(defmethod add-default-hooks ((connection connection))
  (dolist (message '(irc-rpl_isupport-message
                     irc-rpl_whoisuser-message
                     irc-rpl_banlist-message
                     irc-rpl_endofbanlist-message
                     irc-rpl_exceptlist-message
                     irc-rpl_endofexceptlist-message
                     irc-rpl_invitelist-message
                     irc-rpl_endofinvitelist-message
                     irc-rpl_list-message
                     irc-rpl_topic-message
                     irc-rpl_namreply-message
                     irc-rpl_endofnames-message
                     irc-ping-message
                     irc-join-message
                     irc-topic-message
                     irc-part-message
                     irc-quit-message
                     irc-kick-message
                     irc-nick-message
                     irc-mode-message
                     irc-rpl_channelmodeis-message
                     ctcp-time-message
                     ctcp-source-message
                     ctcp-finger-message
                     ctcp-version-message
                     ctcp-ping-message))
      (add-hook connection message #'default-hook)))

(defmethod client-raw-log ((connection connection) message)
  (let ((stream (client-stream connection)))
    (format stream (format nil "RAW LOG: ~A~%" message))
    (force-output stream)))

(defmethod connectedp ((connection connection))
  "Returns t if `connection' is connected to a server and is ready for
input."
  (let ((stream (network-stream connection)))
    (and (streamp stream)
         (open-stream-p stream))))

(defmethod read-message ((connection connection))
  (when (connectedp connection)
    (let ((message (read-irc-message connection)))
      (when *debug-p*
        (format *debug-stream* "~A" (describe message)))
      (when message
        (irc-message-event connection message))
      message))) ; needed because of the "loop while" in read-message-loop

(defvar *process-count* 0)

(defmethod start-process (function name)
  (declare (ignorable name))
  #+allegro (mp:process-run-function name function)
  #+cmu (mp:make-process function :name name)
  #+lispworks (mp:process-run-function name nil function)
  #+sb-thread (sb-thread:make-thread function)
  #+openmcl (ccl:process-run-function name function)
  #+armedbear (ext:make-thread function))

(defun start-background-message-handler (connection)
  "Read messages from the `connection', parse them and dispatch
irc-message-event on them. Returns background process ID if available."
  (flet (#-(and sbcl (not sb-thread))
           (do-loop () (read-message-loop connection)))
    (let ((name (format nil "irc-hander-~D" (incf *process-count*))))
      (declare (ignorable name))
      #+(or allegro cmu lispworks sb-thread openmcl armedbear)
      (start-process #'do-loop name)
      #+(and sbcl (not sb-thread))
      (sb-sys:add-fd-handler (sb-sys:fd-stream-fd
                              (network-stream connection))
                             :input (lambda (fd)
                                      (declare (ignore fd))
                                      (if (listen (network-stream connection))
                                          (read-message connection)
                                        ;; select() returns with no
                                        ;; available data if the stream
                                        ;; has been closed on the other
                                        ;; end (EPIPE)
                                        (sb-sys:invalidate-descriptor
                                         (sb-sys:fd-stream-fd
                                          (network-stream connection)))))))))

(defun stop-background-message-handler (process)
  "Stops a background message handler process returned by the start function."
  (declare (ignorable process))
    #+cmu (mp:destroy-process process)
    #+allegro (mp:process-kill process)
    #+sb-thread (sb-thread:destroy-thread process)
    #+lispworks (mp:process-kill process)
    #+openmcl (ccl:process-kill process)
    #+armedbear (ext:destroy-thread process))

(defun read-message-loop (connection)
  (loop while (read-message connection)))

(defun try-decode-line (line external-formats)
  (loop for external-format in external-formats
        for decoded = nil
        for error = nil
        do (multiple-value-setq (decoded error)
             (handler-case
              (flexi-streams:with-input-from-sequence (in line)
                (let ((flexi (flexi-streams:make-flexi-stream in
;;                                                              :element-type 'character
                                                              :external-format
                                                              (external-format-fixup external-format))))
                  (read-line flexi nil nil)))
              (flexi-streams:flexi-stream-encoding-error ()
                  nil)))
        if decoded
        do (return decoded)))

(defmethod read-irc-message ((connection connection))
  "Read and parse an IRC-message from the `connection'."
  (handler-case
   (multiple-value-bind
       (buf buf-len)
       ;; Note: we cannot use read-line here (or any other
       ;; character based functions), since they may cause conversion
       (read-sequence-until (network-stream connection)
                            (make-array 1024
                                        :element-type '(unsigned-byte 8)
                                        :fill-pointer t)
                            '(13 10))
     (setf (fill-pointer buf) buf-len)
     (let* ((message (create-irc-message (try-decode-line buf *default-incoming-external-formats*))))
       (setf (connection message) connection)
       message))
    (end-of-file ())))
       ;; satisfy read-message-loop assumption of nil when no more messages

(defmethod send-irc-message ((connection connection) command
                             &rest arguments)
  "Turn the arguments into a valid IRC message and send it to the
server, via the `connection'."
  (let ((raw-message (apply #'make-irc-message command arguments)))
    (write-sequence raw-message (output-stream connection))
    (force-output (output-stream connection))
    raw-message))

(defmethod get-hooks ((connection connection) (class symbol))
  "Return a list of all hooks for `class'."
  (gethash class (hooks connection)))

(defmethod add-hook ((connection connection) class hook)
  "Add `hook' to `class'."
  (setf (gethash class (hooks connection))
        (pushnew hook (gethash class (hooks connection)))))

(defmethod remove-hook ((connection connection) class hook)
  "Remove `hook' from `class'."
  (setf (gethash class (hooks connection))
        (delete hook (gethash class (hooks connection)))))

(defmethod remove-hooks ((connection connection) class)
  "Remove all hooks for `class'."
  (setf (gethash class (hooks connection)) nil))

(defmethod remove-all-hooks ((connection connection))
  (clrhash (hooks connection)))

(defmethod case-map-name ((connection connection))
  (let ((case-mapping (assoc "CASEMAPPING" (server-capabilities connection)
                             :test #'equal)))
    (intern (string-upcase (second case-mapping)) (find-package "KEYWORD"))))

(defmethod re-apply-case-mapping ((connection connection))
  (setf (normalized-nickname (user connection))
        (normalize-nickname connection (nickname (user connection))))
  (flet ((set-new-users-hash (object)
           (let ((new-users (make-hash-table :test #'equal)))
             (maphash
              #'(lambda (norm-nick user)
                  (declare (ignore norm-nick))
                  (setf (gethash
                         (setf (normalized-nickname user)
                               (normalize-nickname connection
                                                   (nickname user)))
                         new-users) user))
              (users object))
             (setf (users object) new-users))))

    (set-new-users-hash connection)
    (let ((new-channels (make-hash-table :test #'equal)))
      (maphash #'(lambda (norm-name channel)
                   (declare (ignore norm-name))
                   (setf (gethash
                          (setf (normalized-name channel)
                                (normalize-channel-name connection
                                                        (name channel)))
                          new-channels) channel)
                   (set-new-users-hash channel))
               (channels connection))
      (setf (channels connection) new-channels))))


;;
;; DCC Connection
;;

(defclass dcc-connection ()
  ((user
    :initarg :user
    :accessor user
    :documentation "The user at the other end of this connection.  The
user at this end can be reached via your normal connection object.")
   (network-stream
    :initarg :network-stream
    :accessor network-stream)
   (output-stream
    :initarg :output-stream
    :accessor output-stream
    :initform t)))

(defmethod print-object ((object dcc-connection) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (if (user object)
        (format stream "with ~A@~A"
                (nickname (user object))
                (hostname (user object)))
      "")))

(defun make-dcc-connection (&key (user nil)
                                 (remote-address nil)
                                 (remote-port nil)
                                 (output-stream t))
  (make-instance 'dcc-connection
                 :user user
                 :network-stream (usocket:socket-connect remote-address
                                                         remote-port)
                 :output-stream output-stream))

(defgeneric dcc-close (connection))
(defgeneric send-dcc-message (connection message))

(defmethod read-message ((connection dcc-connection))
  (when (connectedp connection)
    (let ((message (read-line (network-stream connection))))
      (format (output-stream connection) "~A~%" message)
      (force-output (output-stream connection))
      (when *debug-p*
        (format *debug-stream* "~A" (describe message)))
      ;; (dcc-message-event message)
      message))) ; needed because of the "loop while" in read-message-loop

(defmethod send-dcc-message ((connection dcc-connection) message)
  (format (network-stream connection) "~A~%" message)
  (force-output (network-stream connection)))

;; argh.  I want to name this quit but that gives me issues with
;; generic functions.  need to resolve.
(defmethod dcc-close ((connection dcc-connection))
  #+(and sbcl (not sb-thread))
  (sb-sys:invalidate-descriptor
   (sb-sys:fd-stream-fd (network-stream connection)))
  (close (network-stream connection))
  (setf (user connection) nil)
  (setf *dcc-connections* (remove connection *dcc-connections*))
  )

(defmethod connectedp ((connection dcc-connection))
  (let ((stream (network-stream connection)))
    (and (streamp stream)
         (open-stream-p stream))))

;;
;; Channel
;;

(defclass channel ()
  ((name
    :initarg :name
    :accessor name)
   (normalized-name
    :initarg :normalized-name
    :accessor normalized-name)
   (topic
    :initarg :topic
    :accessor topic)
   (modes
    :initarg :modes
    :accessor modes
    :initform '())
   (visibility
    :initarg :visibility
    :accessor visibility
    :initform nil
    :type (member nil :public :private :secret :unknown))
   (users
    :initarg :users
    :accessor users
    :initform (make-hash-table :test #'equal))
   (user-count
    :initarg :user-count
    :accessor user-count
    :initform nil
    :documentation "May not represent the real number of users in the
channel.  Rather, the number returned from the LIST command gets stuck
in there so the user of this library can use it for searching
channels, for instance.  If the value is NIL then the slot has not
been populated by a LIST command.")))

(defmethod print-object ((object channel) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (princ (name object) stream)))

(defun normalize-channel-name (connection string)
  "Normalize `string' so that it represents an all-downcased channel
name."
  (irc-string-downcase (case-map-name connection) string))

(defun make-channel (connection
                     &key (name "")
                          (topic "")
                          (modes nil)
                          (users nil)
                          (user-count nil))
  (let ((channel
         (make-instance 'channel
                        :name name
                        :normalized-name
                        (normalize-channel-name connection name)
                        :topic topic
                        :modes modes
                        :user-count user-count)))
    (dolist (user users)
      (add-user channel user))
    channel))

(defgeneric find-channel (connection channel))
(defgeneric remove-all-channels (connection))
(defgeneric add-channel (connection channel))
(defgeneric remove-channel (connection channel))
(defgeneric remove-users (channel))

(defgeneric mode-name-from-char (connection target mode-char)
  (:documentation "Map the mode character used in the MODE message to a
symbol used internally to describe the mode given a `target'."))

(defgeneric mode-description (connection target mode-name)
  (:documentation "Retrieve a `mode-description' structure for the given
`mode-name' keyword."))

(defgeneric get-mode (target mode)
  (:documentation "Get the value associated with `mode' for `target'
or `nil' if no mode available."))

(defgeneric set-mode (target mode &optional parameter)
  (:documentation "Set the mode designated by the `mode' keyword to a
value passed in `parameter' or T if `parameter' is absent."))

(defgeneric unset-mode (target mode &optional parameter)
  (:documentation
"Sets value of the mode designated by the `mode' keyword to nil.
If the mode holds a list of values `parameter' is used to indicate which
element to remove."))

(defgeneric add-mode (target mode-name mode)
  (:documentation "Add the mode-holding object `mode-value' to `target'
under the access key `mode-name'.

If mode-value is a subtype of irc-mode, it is added as-is.
Otherwise, a mode-object will be generated from the "))
(defgeneric remove-mode (target mode-name)
  (:documentation "Remove the mode-holding object in the `mode-name' key
from `target'."))

(defgeneric has-mode-p (target mode)
  (:documentation "Return a generalised boolean indicating if `target' has
a mode `mode' associated with it."))

(defgeneric has-mode-value-p (target mode value &key key test)
  (:documentation "Return a generalised boolean indicating if `target' has
a mode `mode' associated with the value `value' for given a `key' transform
and `test' test."))

(defmethod find-channel ((connection connection) (channel string))
  "Return channel as designated by `channel'.  If no such channel can
be found, return nil."
  (let ((channel-name (normalize-channel-name connection channel)))
    (gethash channel-name (channels connection))))

(defmethod remove-all-channels ((connection connection))
  "Remove all channels known to `connection'."
  (clrhash (channels connection)))

(defmethod add-channel ((connection connection) (channel channel))
  "Add `channel' to `connection'."
  (setf (gethash (normalized-name channel) (channels connection)) channel))

(defmethod remove-channel ((connection connection) (channel channel))
  "Remove `channel' from `connection'."
  (remhash (normalized-name channel) (channels connection)))

(defmethod remove-users ((channel channel))
  "Remove all users on `channel'."
  (clrhash (users channel))
  (do-property-list (prop val (modes channel))
     (when (and val (eq (value-type val) :user))
       (remf (modes channel) prop))))

(defmethod mode-name-from-char ((connection connection)
                                (target channel) mode-char)
  (declare (ignore target))
  (let ((mode-desc (find mode-char (channel-mode-descriptions connection)
                         :key #'mode-desc-char)))
    (when mode-desc
      (mode-desc-symbol (the mode-description mode-desc)))))

(defmethod mode-description ((connection connection)
                             (target channel) mode-name)
  (declare (ignore target))
  (find mode-name (channel-mode-descriptions connection)
        :key #'mode-desc-symbol))

(defgeneric make-mode (connection target mode-id))

(defmethod make-mode (connection target (mode character))
  (let ((mode-name (mode-name-from-char connection target mode)))
    (make-mode connection target mode-name)))

(defmethod make-mode (connection target (mode symbol))
  (let ((mode-desc (mode-description connection target mode)))
    (make-instance (mode-desc-class mode-desc)
                   :value-type (if (mode-desc-nick-param-p mode-desc)
                                   :user :non-user))))

(defmethod add-mode (target mode-name mode)
  (setf (getf (modes target) mode-name) mode))

(defmethod remove-mode (target mode-name)
  (remf (modes target) mode-name))

(defmethod get-mode (target mode)
  (let ((mode-object (has-mode-p target mode)))
    (when mode-object
      (value mode-object))))

(defmethod set-mode (target mode &optional parameter)
  (set-mode-value (getf (modes target) mode) parameter))

(defmethod unset-mode (target mode &optional parameter)
  (let ((mode (getf (modes target) mode)))
    (when mode
      (unset-mode-value mode parameter))))

(defmethod has-mode-p (target mode)
  (multiple-value-bind
      (indicator value tail)
      (get-properties (modes target) (list mode))
    (when (or indicator value tail)
      value)))

(defmethod has-mode-value-p (target mode value
                                    &key (key #'identity) (test #'equal))
  (let ((mode (getf (modes target) mode)))
    (when mode
      (has-value-p mode value :key key :test test))))

;;
;; User
;;

(defclass user ()
  ((nickname
    :initarg :nickname
    :accessor nickname
    :initform "")
   (normalized-nickname
    :initarg :normalized-nickname
    :accessor normalized-nickname
    :initform "")
   (username
    :initarg :username
    :accessor username
    :initform "")
   (hostname
    :initarg :hostname
    :accessor hostname
    :initform "")
   (realname
    :initarg :realname
    :accessor realname
    :initform "")
   (modes
    :initarg :modes
    :accessor modes
    :initform '())
   (channels
    :initarg :channels
    :accessor channels
    :initform nil)))

(defmethod print-object ((object user) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~A!~A@~A \"~A\""
            (nickname object)
            (username object)
            (hostname object)
            (realname object))))

(defun make-user (connection
                  &key (nickname "")
                       (username "")
                       (hostname "")
                       (realname ""))
  (make-instance 'user
                 :nickname nickname
                 :normalized-nickname (normalize-nickname connection nickname)
                 :username username
                 :hostname hostname
                 :realname realname))

(defun canonicalize-nickname (connection nickname)
  (if (find (char nickname 0)
            (parse-isupport-prefix-argument
             (second (assoc "PREFIX"
                            (server-capabilities connection)
                            :test #'string=))))
      (substring nickname 1)
      nickname))

(defun normalize-nickname (connection string)
  "Normalize `string' so that represents an all-downcased IRC
nickname."
  (irc-string-downcase (case-map-name connection) string))

(defgeneric find-user (connection nickname))
(defgeneric add-user (object user))
(defgeneric remove-all-users (connection))
(defgeneric remove-user (object user))
(defgeneric remove-user-everywhere (connection user))
(defgeneric find-or-make-user (connection nickname
                                          &key username hostname realname))
(defgeneric change-nickname (connection user new-nickname))

(defmethod find-user ((connection connection) (nickname string))
  "Return user as designated by `nickname' or nil if no such user is
known."
  (let ((nickname (normalize-nickname connection nickname)))
    (or (gethash nickname (users connection))
        (when (string= nickname (nickname (user connection)))
          (user connection)))))

; what if the user is not on any channels?
(defmethod add-user ((connection connection) (user user))
  "Add `user' to `connection'."
  (setf (gethash (normalized-nickname user) (users connection)) user))

(defmethod add-user ((channel channel) (user user))
  (setf (gethash (normalized-nickname user) (users channel)) user)
  (pushnew channel (channels user)))

(defmethod remove-all-users ((connection connection))
  "Remove all users known to `connection'."
  (clrhash (users connection)))

(defmethod remove-user ((channel channel) (user user))
  "Remove `user' from `channel' and `channel' from `user'."
  (remhash (normalized-nickname user) (users channel))
  (setf (channels user) (remove channel (channels user)))
  (do-property-list (prop val (modes channel))
     (when (and val (eq (value-type val) :user))
       (unset-mode channel prop user))))

(defmethod remove-channel ((user user) (channel channel))
  "Remove `channel' from `user'."
  (setf (channels user) (remove channel (channels user))))

(defmethod remove-user ((connection connection) (user user))
  "Remove `user' from `connection' but leave user in any channels he
may be already be on."
  (remhash (normalized-nickname user) (users connection)))

(defmethod remove-user-everywhere ((connection connection) (user user))
  "Remove `user' anywhere present in the `connection'."
  (dolist (channel (channels user))
    (remove-user channel user))
  (remove-user connection user))

(defmethod mode-name-from-char ((connection connection)
                                (target user) mode-char)
  (declare (ignore target))
  (let ((mode-desc (find mode-char (user-mode-descriptions connection)
                         :key #'mode-desc-char)))
    (when mode-desc
      (mode-desc-symbol (the mode-description mode-desc)))))

(defmethod mode-description ((connection connection)
                             (target user) mode-name)
  (declare (ignore target))
  (find mode-name (user-mode-descriptions connection)
        :key #'mode-desc-symbol))

(defmethod find-or-make-user ((connection connection) nickname &key (username "")
                              (hostname "") (realname ""))
  (let ((user (find-user connection nickname)))
    (unless user
      (setf user
            (make-user connection
                       :nickname nickname
                       :username username
                       :hostname hostname
                       :realname realname)))
    (labels ((update-slot-if-known (slotname value)
               (when (string= (slot-value user slotname) "")
                 (setf (slot-value user slotname) value))))
      (update-slot-if-known 'username username)
      (update-slot-if-known 'hostname hostname)
      (update-slot-if-known 'realname realname))
    user))

(defmethod change-nickname ((connection connection) (user user) new-nickname)
  (let ((channels (channels user)))
    (remove-user connection user)
    (dolist (channel channels)
      (remove-user channel user))
    (setf (nickname user) new-nickname)
    (setf (normalized-nickname user)
          (normalize-nickname connection new-nickname))
    (dolist (channel channels)
      (add-user channel user))
    (add-user connection user)
    user))

;; IRC Message
;;

(defclass irc-message ()
  ((source
    :accessor source
    :initarg :source
    :type string)
   (user
    :accessor user
    :initarg :user)
   (host
    :accessor host
    :initarg :host
    :type string)
   (command
    :accessor command
    :initarg :command
    :type string)
   (arguments
    :accessor arguments
    :initarg :arguments
    :type list)
   (connection
    :accessor connection
    :initarg :connection)
   (received-time
    :accessor received-time
    :initarg :received-time)
   (raw-message-string
    :accessor raw-message-string
    :initarg :raw-message-string
    :type string)))

(defmethod print-object ((object irc-message) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~A ~A" (source object) (command object))))

;;Compat code; remove after 2006-08-01

(defgeneric trailing-argument (message))
(defmethod trailing-argument ((message irc-message))
  (warn "Use of deprecated function irc:trailing-argument")
  (car (last (arguments message))))

(defgeneric self-message-p (message))
(defgeneric find-irc-message-class (type))
(defgeneric client-log (connection message &optional prefix))
(defgeneric apply-to-hooks (message))

(defmethod self-message-p ((message irc-message))
  "Did we send this message?"
  (string-equal (source message)
                (nickname (user (connection message)))))

(defclass irc-error-reply (irc-message) ())

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun intern-message-symbol (prefix name)
    "Intern based on symbol-name to support case-sensitive mlisp"
    (intern
     (concatenate 'string
                  (symbol-name prefix)
                  "-"
                  (symbol-name name)
                  "-"
                  (symbol-name '#:message))))

  (defun define-irc-message (command)
    (let ((name (intern-message-symbol :irc command)))
      `(progn
        (defmethod find-irc-message-class ((type (eql ,command)))
          (find-class ',name))
        (export ',name)
        (defclass ,name (irc-message) ())))))

(defmacro create-irc-message-classes (class-list)
  `(progn ,@(mapcar #'define-irc-message class-list)))

;; should perhaps wrap this in an eval-when?
(create-irc-message-classes #.(remove-duplicates (mapcar #'second *reply-names*)))
(create-irc-message-classes (:privmsg :notice :kick :topic :error :mode :ping
                             :nick :join :part :quit :kill :pong :invite))

(defmethod find-irc-message-class (type)
  (declare (ignore type))
  (find-class 'irc-message))

(defmethod client-log ((connection connection) (message irc-message) &optional (prefix ""))
  (let ((stream (client-stream connection)))
    (format stream "~A~A: ~A: ~A~{ ~A~} \"~A\"~%"
            prefix
            (received-time message)
            (command message)
            (source message)
            (butlast (arguments message))
            (car (last (arguments message))))
    (force-output stream)))

(defmethod apply-to-hooks ((message irc-message))
  (let ((connection (connection message)))
    (dolist (hook (get-hooks connection (class-name (class-of message))))
      (funcall hook message))))

;;
;; CTCP Message
;;

(defclass ctcp-mixin ()
  ((ctcp-command
    :initarg :ctcp-command
    :accessor ctcp-command)))

(defclass standard-ctcp-message (ctcp-mixin irc-message) ())

(defgeneric find-ctcp-message-class (type))
(defgeneric ctcp-request-p (message))
(defgeneric ctcp-reply-p (message))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun define-ctcp-message (ctcp-command)
    (let ((name (intern-message-symbol :ctcp ctcp-command)))
      `(progn
        (defmethod find-ctcp-message-class ((type (eql ,ctcp-command)))
          (find-class ',name))
        (export ',name)
        (defclass ,name (ctcp-mixin irc-message) ())))))

(defmacro create-ctcp-message-classes (class-list)
  `(progn ,@(mapcar #'define-ctcp-message class-list)))

;; should perhaps wrap this in an eval-when?
(create-ctcp-message-classes (:action :source :finger :ping
                               :version :userinfo :time :dcc-chat-request
                               :dcc-send-request))

(defmethod find-ctcp-message-class (type)
  (declare (ignore type))
  (find-class 'standard-ctcp-message))

(defmethod ctcp-request-p ((message ctcp-mixin))
  (string= (command message) :privmsg))

(defmethod ctcp-reply-p ((message ctcp-mixin))
  (string= (command message) :notice))

(defmethod client-log ((connection connection) (message ctcp-mixin) &optional (prefix ""))
  (let ((stream (client-stream connection)))
    (format stream "~A~A: ~A (~A): ~A~{ ~A~} \"~A\"~%"
            prefix
            (received-time message)
            (command message)
            (ctcp-command message)
            (source message)
            (butlast (arguments message))
            (car (last (arguments message))))
    (force-output stream)))

