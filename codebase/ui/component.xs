; Component system for XS UI
; State management and lifecycle

; VNode and Attr types from vdom.xs
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; Need to include vdom definitions
(let div (fn (attrs children) (Element "div" attrs children)))
(let p (fn (attrs children) (Element "p" attrs children)))
(let h1 (fn (attrs children) (Element "h1" attrs children)))
(let button (fn (attrs children) (Element "button" attrs children)))
(let text (fn (content) (Text content)))
(let fragment (fn (children) (Fragment children)))
(let on-click (fn (handler) (EventHandler "click" handler)))

; Helper functions are now built-in!
; str-concat and int-to-string are available as builtin functions
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h rest) (cons (f h) (map f rest)))))

; Component state type
(type State
  (State String Int))  ; name and value for simplicity

; Props type (simplified for now)
(type Props
  (Props (List (fn (String) String))))  ; key-value getter functions

; Component definition
(type Component
  (StatelessComponent (fn (Props) VNode))
  (StatefulComponent 
    State 
    (fn (State Props) VNode)
    (fn (State Int) State)))  ; render and update functions

; Create stateless component
(let create-component (fn (render)
  (StatelessComponent render)))

; Create stateful component
(let create-stateful-component (fn (initial-state render update)
  (StatefulComponent initial-state render update)))

; Example: Counter component
(let counter-component
  (create-stateful-component
    (State "counter" 0)
    (fn (state props)
      (match state
        ((State name value)
          (div (list)
               (list (h1 (list) (list (text "Counter Example")))
                     (p (list) (list (text (str-concat "Count: " (int-to-string value)))))
                     (button (list (on-click (fn (x) (+ x 1))))
                             (list (text "Increment"))))))))
    (fn (state delta)
      (match state
        ((State name value)
          (State name (+ value delta)))))))

; Component composition helper
(let compose-components (fn (components)
  (fragment (map (fn (comp) 
    (match comp
      ((StatelessComponent render) (render (Props (list))))
      ((StatefulComponent state render update) (render state (Props (list))))))
    components))))