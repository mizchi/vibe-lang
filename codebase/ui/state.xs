; State management system for XS UI
; Inspired by React hooks and Redux

; Import needed types
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; Action type for state updates
(type Action
  (SetValue Int)
  (Increment)
  (Decrement)
  (Reset)
  (Custom String Int))  ; Custom action with type and payload

; State container with history
(type StateContainer
  (StateContainer 
    Int           ; current value
    (List Int)    ; history
    Int))         ; version number

; Create initial state container
(let create-state (fn (initial-value)
  (StateContainer initial-value (list initial-value) 0)))

; State reducer - pure function that handles actions
(let reducer (fn (state action)
  (match state
    ((StateContainer value history version)
      (match action
        ((SetValue new-value)
          (StateContainer new-value (cons new-value history) (Int.add version 1)))
        ((Increment)
          (let new-value (Int.add value 1) in
            (StateContainer new-value (cons new-value history) (Int.add version 1))))
        ((Decrement)
          (let new-value (Int.sub value 1) in
            (StateContainer new-value (cons new-value history) (Int.add version 1))))
        ((Reset)
          (match history
            ((list) state)  ; No history, keep current
            ((list first rest) 
              (StateContainer first (list first) (Int.add version 1)))))
        ((Custom type payload)
          ; Handle custom actions - for now just set value
          (StateContainer payload (cons payload history) (Int.add version 1))))))))

; Get current value from state container
(let get-value (fn (state)
  (match state
    ((StateContainer value _ _) value))))

; Get history from state container
(let get-history (fn (state)
  (match state
    ((StateContainer _ history _) history))))

; Create a store that manages state and subscriptions
(type Store
  (Store 
    StateContainer                    ; current state
    (List (fn (StateContainer) Int))  ; listeners
    (fn (Action) StateContainer)))    ; dispatch function

; Subscription management
(rec notify-listeners (listeners state)
  (match listeners
    ((list) 0)
    ((list listener rest)
      (let _ (listener state) in
        (notify-listeners rest state)))))

; Create store with initial state
(let create-store (fn (initial-value)
  (let initial-state (create-state initial-value) in
    (rec dispatch (action)
      (let new-state (reducer initial-state action) in
        (let _ (notify-listeners (list) new-state) in
          new-state)))
    (Store initial-state (list) dispatch))))

; Hook-like interface for components
(type UseStateResult
  (UseStateResult 
    Int                    ; current value
    (fn (Action) Int)))    ; dispatch function

; useState hook equivalent
(let use-state (fn (initial-value)
  (let state (create-state initial-value) in
    (let dispatch (fn (action)
      (get-value (reducer state action))) in
      (UseStateResult (get-value state) dispatch)))))

; Example usage in a component
(let counter-with-hooks (fn ()
  (match (use-state 0)
    ((UseStateResult value dispatch)
      (div (list)
           (list (h1 (list) (list (text "Counter with State Management")))
                 (p (list) (list (text (String.concat "Count: " (Int.toString value)))))
                 (button (list (on-click (fn (_) (dispatch Increment))))
                         (list (text "+")))
                 (button (list (on-click (fn (_) (dispatch Decrement))))
                         (list (text "-")))
                 (button (list (on-click (fn (_) (dispatch Reset))))
                         (list (text "Reset"))))))))

; Helper functions
(let div (fn (attrs children) (Element "div" attrs children)))
(let p (fn (attrs children) (Element "p" attrs children)))
(let h1 (fn (attrs children) (Element "h1" attrs children)))
(let button (fn (attrs children) (Element "button" attrs children)))
(let text (fn (content) (Text content)))
(let on-click (fn (handler) (EventHandler "click" handler)))