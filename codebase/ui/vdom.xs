; Virtual DOM library for XS
; React-like declarative UI library implementation

; VNode type definition
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

; Attribute type
(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; Helper functions for creating VNodes
(let text (fn (content) (Text content)))

(let element (fn (tag attrs children)
  (Element tag attrs children)))

(let fragment (fn (children) (Fragment children)))

; Common HTML elements
(let div (fn (attrs children) (element "div" attrs children)))
(let span (fn (attrs children) (element "span" attrs children)))
(let p (fn (attrs children) (element "p" attrs children)))
(let h1 (fn (attrs children) (element "h1" attrs children)))
(let button (fn (attrs children) (element "button" attrs children)))

; Attribute helpers
(let attr (fn (name value) (AttrValue name value)))
(let on-click (fn (handler) (EventHandler "click" handler)))

; Example usage:
; (div (list (attr "class" "container"))
;      (list (h1 (list) (list (text "Hello, World!")))
;            (button (list (on-click (fn () (print "Clicked!"))))
;                    (list (text "Click me")))))