;;;; Erlangen portable function call.

(in-package :erlangen.distribution.call)

(defun callable-p (call)
  "Predicate to check if CALL is callable."
  (and (listp call)
       (symbolp (first call))))

(deftype call ()
  "*Syntax:*

   _call_::= {(}_function_ _argument_\\*{)}

   *Arguments and Values:*

   _function_—a _symbol_ denoting a _function_.

   _argument_—a _serializable object_.

   *Description:*

   A _call_ denotes a portable function call to be invoked on a given
   _node_. A _call_ is a _list_ whose first element is a _symbol_
   denoting a _function_ and whose remaining elements are arguments to be
   applied to the denoted _function_."
  '(satisfies callable-p))

(defun make-function (call)
  "Return function with no arguments which applies CALL."
  (check-type call call)
  (destructuring-bind (function &rest arguments) call
    (lambda ()
      (apply function arguments))))
