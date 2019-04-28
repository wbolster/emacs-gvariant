;;; gvariant.el --- GVariant (Glib/Gnome) helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; todo

;; More information

;; - https://developer.gnome.org/glib/stable/gvariant-text.html
;; - https://developer.gnome.org/glib/stable/gvariant-format-strings.html

;;; Code:

(require 'parsec)

(defconst gvariant--special-chars
  '((?\" . ?\")
    (?\' . ?\')
    (?\\ . ?\\)
    (?a . ?\a)
    (?b . ?\b)
    (?f . ?\f)
    (?n . ?\n)
    (?r . ?\r)
    (?t . ?\t)
    (?v . ?\v))
  "GVariant string escapes, translated to elisp.")

(defconst gvariant--format-string-regex
  (concat "[" (regexp-quote "bynqiuxthdsogvam(){}@*?r&^") "]+")
  "Regular expression to detect GVariant format strings.")

(defconst gvariant--type-keywords-regex
  "\\(boolean\\|byte\\|int16\\|uint16\\|int32\\|uint32\\|handle\\|int64\\|uint64\\|double\\|string\\|objectpath\\|signature\\)"
  "Regular expression to detect GVariant type keywords.")

(defun gvariant-parse (s)
  "Parse the string representation of a GVariant value from string S."
  (let ((case-fold-search nil))
    (parsec-with-input s
      (parsec-return
          (gvariant--value)
        (parsec-eob)))))

(defun gvariant--value ()
  "Parse a GVariant value."
  (parsec-optional
   (parsec-try
    (gvariant--type-prefix)))
  (parsec-or
   (gvariant--boolean)
   (gvariant--number)
   (gvariant--string)
   (gvariant--array)
   (gvariant--tuple)
   (gvariant--dictionary)))

(defun gvariant--whitespace ()
  "Parse whitespace."
  (parsec-many (parsec-ch ?\s)))

(defun gvariant--type-prefix ()
  "Parse (and ignore) a GVariant type prefix."
  (parsec-return
      (parsec-or
       (parsec-re gvariant--type-keywords-regex)
       (parsec-re gvariant--format-string-regex))
    (parsec-ch ?\s)
    (gvariant--whitespace)))

(defun gvariant--boolean ()
  "Parse a GVariant boolean."
  (parsec-or
   (parsec-and (parsec-str "true") t)
   (parsec-and (parsec-str "false") nil)))

(defun gvariant--number ()
  "Parse a GVariant number."
  (parsec-or
   (gvariant--octal)
   (gvariant--hexadecimal)
   (gvariant--decimal)))

(defun gvariant--decimal ()
  "Parse a GVariant integer or float using decimal notation."
  (string-to-number
   (parsec-try
    (parsec-collect-as-string
     (parsec-optional (parsec-one-of ?- ?+))
     (parsec-or (parsec-re "[0-9]+\\.[0-9]*")
                (parsec-re "\\.[0-9]+")
                (parsec-re "[1-9][0-9]*"))
     (parsec-optional (parsec-re "[Ee]\\-?[0-9]+"))))))

(defun gvariant--octal ()
  "Parse a GVariant integer in octal notation."
  (string-to-number
   (parsec-try
    (parsec-collect-as-string
     (parsec-optional (parsec-one-of ?- ?+))
     (parsec-re "0[0-7]+")))
   8))

(defun gvariant--hexadecimal ()
  "Parse a GVariant integer in hexadecimal notation."
  (string-to-number
   (parsec-try
    (parsec-collect-as-string
     (parsec-optional (parsec-one-of ?- ?+))
     (parsec-and (parsec-str "0x") nil)
     (parsec-re "[0-9a-zA-Z]+")))
   16))

(defsubst gvariant--char (quote-char)
  "Parse a character inside a GVariant string delimited by QUOTE-CHAR."
  (parsec-or
   (parsec-and (parsec-ch ?\\) (gvariant--escaped-char))
   (parsec-none-of quote-char ?\\)))

(defun gvariant--escaped-char ()
  "Parse a GVariant string escape."
  (let ((case-fold-search nil))
    (parsec-or
     (char-to-string
      (assoc-default
       (string-to-char
        (parsec-satisfy (lambda (x) (assq x gvariant--special-chars))))
       gvariant--special-chars))
     (parsec-and (parsec-ch ?u) (gvariant--unicode-hex 4))
     (parsec-and (parsec-ch ?U) (gvariant--unicode-hex 8)))))

(defun gvariant--unicode-hex (n)
  "Parse a GVariant hexadecimal unicode value consisting of N hex digits."
  (let ((regex (format "[0-9a-zA-z]\\{%d\\}" n)))
    (format "%c" (string-to-number (parsec-re regex) 16))))

(defun gvariant--string ()
  "Parse a GVariant string."
  (parsec-or
   (parsec-between (parsec-ch ?\')
                   (parsec-ch ?\')
                   (parsec-many-as-string (gvariant--char ?\')))
   (parsec-between (parsec-ch ?\")
                   (parsec-ch ?\")
                   (parsec-many-as-string (gvariant--char ?\")))))

(defun gvariant--array ()
  "Parse a GVariant array."
  (vconcat
   (parsec-try
    (parsec-between
     (parsec-ch ?\[)
     (parsec-ch ?\])
     (gvariant--comma-separated-values)))))

(defun gvariant--tuple ()
  "Parse a GVariant tuple."
  (parsec-try
   (parsec-between
    (parsec-ch ?\()
    (parsec-ch ?\))
    (gvariant--comma-separated-values))))

(defsubst gvariant--comma-separator ()
  "Parse a comma separator, optionally enclosed by whitespace."
  (parsec-and
   (gvariant--whitespace)
   (parsec-ch ?,)
   (gvariant--whitespace)
   nil))

(defun gvariant--comma-separated-values ()
  "Parse a comma separated sequence of GVariant values (array or tuple contents)."
  (parsec-sepby
   (gvariant--value)
   (gvariant--comma-separator)))

(defun gvariant--dictionary ()
  "Parse a GVariant dictionary."
  (parsec-or
   (gvariant--dictionary-mapping)
   (gvariant--dictionary-entries-array)))

(defun gvariant--dictionary-mapping ()
  "Parse a GVariant dictionary expressed as a mapping."
  (parsec-try
   (parsec-between
    (parsec-ch ?\{)
    (parsec-ch ?\})
    (parsec-sepby
     (parsec-collect*
      (gvariant--value)
      (parsec-and
       (gvariant--whitespace)
       (parsec-ch ?:)
       (gvariant--whitespace)
       nil)
      (gvariant--value))
     (gvariant--comma-separator)))))

(defsubst gvariant--dictionary-entry ()
  "Parse a GVariant dictionary entry."
  (parsec-between
   (parsec-ch ?\{)
   (parsec-ch ?\})
   (parsec-collect*
    (gvariant--value)
    (parsec-and
     (gvariant--comma-separator)
     nil)
    (gvariant--value))))

(defun gvariant--dictionary-entries-array ()
  "Parse an array of GVariant dictionary entries."
  (parsec-try
   (parsec-between
    (parsec-ch ?\[)
    (parsec-ch ?\])
    (parsec-sepby
     (gvariant--dictionary-entry)
     (gvariant--comma-separator)))))


;;; Tests

(ert-deftest gvariant--test-parsing-boolean ()
  (should (equal (gvariant-parse "true") t))
  (should (equal (gvariant-parse "false") nil))
  (should (equal (gvariant-parse "boolean true") t)))

(ert-deftest gvariant--test-parsing-number ()
  (should (equal (gvariant-parse "123") 123))
  (should (equal (gvariant-parse "+123") 123))
  (should (equal (gvariant-parse "-123") -123))
  (should (equal (gvariant-parse "37.5") 37.5))
  (should (equal (gvariant-parse ".5") .5))
  (should (equal (gvariant-parse "-.5") -.5))
  (should (equal (gvariant-parse "3e1") 30.0))
  (should (equal (gvariant-parse "3.75e1") 37.5))
  (should (equal (gvariant-parse "300e-1") 30.0))
  (should (equal (gvariant-parse "0123") 83))
  (should (equal (gvariant-parse "+0123") 83))
  (should (equal (gvariant-parse "-0123") -83))
  (should (equal (gvariant-parse "0xff") 255))
  (should (equal (gvariant-parse "+0xff") 255))
  (should (equal (gvariant-parse "-0xff") -255))
  (should (equal (gvariant-parse "uint32 12") 12))
  (should (equal (gvariant-parse "int32 12") 12)))

(ert-deftest gvariant--test-parsing-string ()
  (should (equal (gvariant-parse "'foo'") "foo"))
  (should (equal (gvariant-parse "string 'foo'") "foo"))
  (should (equal (gvariant-parse "\"foo\"") "foo"))
  (should (equal (gvariant-parse "'\\a\\t\\b\\n'") "\a\t\b\n"))
  (should (equal (gvariant-parse "'\\u2603\\U0001f984'") "☃🦄")))

(ert-deftest gvariant--test-parsing-array ()
  (should (equal (gvariant-parse "['foo', 'bar']") ["foo" "bar"]))
  (should (equal (gvariant-parse "@as []") [])))

(ert-deftest gvariant--test-parsing-tuple ()
  (should (equal (gvariant-parse "('foo', 123)")
                 '("foo" 123)))
  (should (equal (gvariant-parse "('a', 1, [3], [])")
                 '("a" 1 [3] []))))

(ert-deftest gvariant--test-parsing-dictionary ()
  (should (equal (gvariant-parse
                  "{'a': 'aa', 'b': 'bb'}")
                 '(("a" "aa") ("b" "bb"))))
  (should (equal (gvariant-parse
                  "[{1, \"one\"}, {2, \"two\"}, {3, \"three\"}]")
                 '((1 "one") (2 "two") (3 "three")))))

(provide 'gvariant)
;;; gvariant ends here