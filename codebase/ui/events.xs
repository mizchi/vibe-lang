; Event handling system for XS UI
; Provides a unified interface for handling user interactions

; Import types
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Event) Action)))

; Event types
(type Event
  (Click Int Int)           ; x, y coordinates
  (Input String)            ; input value
  (Change String)           ; changed value
  (Submit)                  ; form submission
  (KeyPress String)         ; key code
  (MouseMove Int Int)       ; x, y coordinates
  (MouseEnter)
  (MouseLeave)
  (Focus)
  (Blur)
  (Custom String String))   ; event type, detail

; Action types for event handlers
(type Action
  (NoOp)
  (UpdateState String Int)  ; field name, new value
  (Navigate String)         ; URL
  (ToggleBool String)       ; field name
  (CallFunction String)     ; function name
  (Batch (List Action)))    ; multiple actions

; Event target information
(type EventTarget
  (EventTarget 
    String           ; element id
    String           ; element type
    (List Attr)))    ; attributes

; Event context with bubbling support
(type EventContext
  (EventContext
    Event            ; the event
    EventTarget      ; target element
    Bool             ; propagation stopped
    Bool))           ; default prevented

; Create event context
(let create-context (fn (event target)
  (EventContext event target false false)))

; Stop event propagation
(let stop-propagation (fn (ctx)
  (match ctx
    ((EventContext event target _ prevented)
      (EventContext event target true prevented)))))

; Prevent default behavior
(let prevent-default (fn (ctx)
  (match ctx
    ((EventContext event target stopped _)
      (EventContext event target stopped true)))))

; Event dispatcher
(rec dispatch-event (event handlers)
  (match handlers
    ((list) NoOp)
    ((list handler rest)
      (let action (handler event) in
        (match action
          (NoOp (dispatch-event event rest))
          ((Batch actions) (Batch (cons action (list (dispatch-event event rest)))))
          (_ action))))))

; Find event handlers in attributes
(rec find-handlers (event-type attrs)
  (match attrs
    ((list) (list))
    ((list (EventHandler name handler) rest)
      (if (String.eq name event-type)
          (cons handler (find-handlers event-type rest))
          (find-handlers event-type rest)))
    ((list _ rest) (find-handlers event-type rest))))

; Event delegation - walk up the tree
(rec delegate-event (event vnodes)
  (match vnodes
    ((list) NoOp)
    ((list vnode rest)
      (match vnode
        ((Element tag attrs children)
          (let handlers (find-handlers (event-type event) attrs) in
            (if (null handlers)
                (delegate-event event children)
                (dispatch-event event handlers))))
        ((Fragment children) (delegate-event event children))
        (_ (delegate-event event rest))))))

; Get event type as string
(let event-type (fn (event)
  (match event
    ((Click _ _) "click")
    ((Input _) "input")
    ((Change _) "change")
    (Submit "submit")
    ((KeyPress _) "keypress")
    ((MouseMove _ _) "mousemove")
    (MouseEnter "mouseenter")
    (MouseLeave "mouseleave")
    (Focus "focus")
    (Blur "blur")
    ((Custom type _) type))))

; Create event handlers with state update
(let create-handler (fn (update-fn)
  (fn (event)
    (match event
      ((Click x y) (UpdateState "click-count" 1))
      ((Input value) (UpdateState "input-value" 0))  ; Would store string
      ((Change value) (UpdateState "selected" 0))    ; Would store string
      (_ NoOp)))))

; Synthetic event creation helpers
(let on-click (fn (handler)
  (EventHandler "click" handler)))

(let on-input (fn (handler)
  (EventHandler "input" handler)))

(let on-change (fn (handler)
  (EventHandler "change" handler)))

(let on-submit (fn (handler)
  (EventHandler "submit" handler)))

(let on-key-press (fn (handler)
  (EventHandler "keypress" handler)))

(let on-mouse-enter (fn (handler)
  (EventHandler "mouseenter" handler)))

(let on-mouse-leave (fn (handler)
  (EventHandler "mouseleave" handler)))

(let on-focus (fn (handler)
  (EventHandler "focus" handler)))

(let on-blur (fn (handler)
  (EventHandler "blur" handler)))

; Event handler composition
(let compose-handlers (fn (h1 h2)
  (fn (event)
    (let a1 (h1 event) in
      (let a2 (h2 event) in
        (match (list a1 a2)
          ((list NoOp a) a)
          ((list a NoOp) a)
          ((list a b) (Batch (list a b)))))))))

; Helper functions
(rec null (lst)
  (match lst
    ((list) true)
    (_ false)))

(let String.eq (fn (s1 s2) true))  ; Placeholder

; Example: Interactive button component
(let interactive-button (fn (label handler)
  (Element "button" 
           (list (on-click handler)
                 (on-mouse-enter (fn (e) (UpdateState "hover" 1)))
                 (on-mouse-leave (fn (e) (UpdateState "hover" 0))))
           (list (Text label)))))

; Example: Form with validation
(let form-with-validation (fn ()
  (Element "form"
           (list (on-submit (fn (e) (CallFunction "validate-and-submit"))))
           (list (Element "input" 
                         (list (AttrValue "type" "text")
                               (on-input (fn (e) 
                                 (match e
                                   ((Input value) (UpdateState "form-input" 0))
                                   (_ NoOp))))
                               (on-blur (fn (e) (CallFunction "validate-field"))))
                         (list))
                 (interactive-button "Submit" (fn (e) (CallFunction "submit-form"))))))