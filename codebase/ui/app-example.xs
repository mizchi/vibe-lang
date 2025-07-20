; Complete UI application example using XS UI library
; Demonstrates state management, event handling, and rendering

; Import all UI modules (in a real implementation, would use proper imports)

; VNode types
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Event) Action)))

; Event and Action types
(type Event
  (Click Int Int)
  (Input String)
  (Change String)
  (Submit))

(type Action
  (NoOp)
  (Increment)
  (Decrement)
  (SetText String)
  (AddTodo)
  (ToggleTodo Int)
  (RemoveTodo Int))

; Application state
(type AppState
  (AppState 
    Int              ; counter value
    String           ; input text
    (List Todo)))    ; todo items

(type Todo
  (Todo Int String Bool))  ; id, text, completed

; Initial state
(let initial-state
  (AppState 0 "" (list)))

; State reducer
(rec reducer (state action)
  (match state
    ((AppState counter text todos)
      (match action
        (Increment 
          (AppState (Int.add counter 1) text todos))
        (Decrement
          (AppState (Int.sub counter 1) text todos))
        ((SetText new-text)
          (AppState counter new-text todos))
        (AddTodo
          (if (String.eq text "")
              state
              (let new-id (List.length todos) in
                (let new-todo (Todo new-id text false) in
                  (AppState counter "" (List.cons new-todo todos))))))
        ((ToggleTodo id)
          (AppState counter text (toggle-todo-by-id id todos)))
        ((RemoveTodo id)
          (AppState counter text (remove-todo-by-id id todos)))
        (_ state)))))

; Helper functions for todo operations
(rec toggle-todo-by-id (id todos)
  (match todos
    ((list) (list))
    ((list (Todo tid text completed) rest)
      (if (Int.eq tid id)
          (List.cons (Todo tid text (not completed)) rest)
          (List.cons (Todo tid text completed) (toggle-todo-by-id id rest))))))

(rec remove-todo-by-id (id todos)
  (match todos
    ((list) (list))
    ((list (Todo tid text completed) rest)
      (if (Int.eq tid id)
          rest
          (List.cons (Todo tid text completed) (remove-todo-by-id id rest))))))

; UI Components

; Counter component
(let counter-component (fn (count)
  (Element "div" (list (AttrValue "class" "counter"))
           (list (Element "h2" (list) (list (Text "Counter")))
                 (Element "p" (list) 
                         (list (Text (String.concat "Count: " (Int.toString count)))))
                 (Element "button" 
                         (list (EventHandler "click" (fn (_) Increment)))
                         (list (Text "+")))
                 (Element "button"
                         (list (EventHandler "click" (fn (_) Decrement)))
                         (list (Text "-")))))))

; Todo item component
(let todo-item (fn (todo)
  (match todo
    ((Todo id text completed)
      (Element "li" 
               (list (AttrValue "class" (if completed "completed" "active")))
               (list (Element "span" 
                             (list (EventHandler "click" (fn (_) (ToggleTodo id))))
                             (list (Text text)))
                     (Element "button"
                             (list (EventHandler "click" (fn (_) (RemoveTodo id))))
                             (list (Text "×"))))))))

; Todo list component
(let todo-list-component (fn (input-text todos)
  (Element "div" (list (AttrValue "class" "todo-list"))
           (list (Element "h2" (list) (list (Text "Todo List")))
                 (Element "div" (list (AttrValue "class" "todo-input"))
                         (list (Element "input"
                                       (list (AttrValue "type" "text")
                                             (AttrValue "value" input-text)
                                             (AttrValue "placeholder" "Enter a todo...")
                                             (EventHandler "input" (fn (e)
                                               (match e
                                                 ((Input value) (SetText value))
                                                 (_ NoOp)))))
                                       (list))
                               (Element "button"
                                       (list (EventHandler "click" (fn (_) AddTodo)))
                                       (list (Text "Add")))))
                 (Element "ul" (list)
                         (List.map todo-item todos))))))

; Main app component
(let app-component (fn (state)
  (match state
    ((AppState counter input-text todos)
      (Element "div" (list (AttrValue "class" "app"))
               (list (Element "h1" (list) (list (Text "XS UI Demo App")))
                     (counter-component counter)
                     (todo-list-component input-text todos)))))))

; Render the initial app
(let render-app (fn (state)
  (app-component state)))

; Event loop simulation (in a real app, this would be handled by the runtime)
(let handle-event (fn (state event action)
  (reducer state action)))

; Helper functions
(rec List.map (f lst)
  (match lst
    ((list) (list))
    ((list h rest) (List.cons (f h) (List.map f rest)))))

(rec List.length (lst)
  (match lst
    ((list) 0)
    ((list _ rest) (Int.add 1 (List.length rest)))))

(let List.cons (fn (h t) (cons h t)))

(let not (fn (b) (if b false true)))

(let String.eq (fn (s1 s2) false))  ; Placeholder
(let Int.eq (fn (a b) (match (Int.sub a b) (0 true) (_ false))))

; CSS styles as a string (would be in a separate file in real app)
(let app-styles "
.app {
  max-width: 600px;
  margin: 0 auto;
  padding: 20px;
  font-family: sans-serif;
}

.counter {
  margin-bottom: 30px;
  padding: 20px;
  border: 1px solid #ddd;
  border-radius: 5px;
}

.counter button {
  margin: 0 5px;
  padding: 5px 15px;
  font-size: 18px;
}

.todo-list {
  padding: 20px;
  border: 1px solid #ddd;
  border-radius: 5px;
}

.todo-input {
  display: flex;
  margin-bottom: 20px;
}

.todo-input input {
  flex: 1;
  padding: 10px;
  font-size: 16px;
  border: 1px solid #ddd;
  border-radius: 3px;
}

.todo-input button {
  margin-left: 10px;
  padding: 10px 20px;
  background: #007bff;
  color: white;
  border: none;
  border-radius: 3px;
  cursor: pointer;
}

.todo-list ul {
  list-style: none;
  padding: 0;
}

.todo-list li {
  padding: 10px;
  margin-bottom: 5px;
  background: #f8f9fa;
  border-radius: 3px;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.todo-list li.completed span {
  text-decoration: line-through;
  opacity: 0.6;
}

.todo-list li span {
  cursor: pointer;
}

.todo-list li button {
  background: #dc3545;
  color: white;
  border: none;
  padding: 5px 10px;
  border-radius: 3px;
  cursor: pointer;
}
")

; Generate complete HTML page
(let generate-html (fn (state)
  (let app-vnode (render-app state) in
    (Element "html" (list)
             (list (Element "head" (list)
                           (list (Element "title" (list) (list (Text "XS UI Demo")))
                                 (Element "style" (list) (list (Text app-styles)))))
                   (Element "body" (list)
                           (list app-vnode))))))

; Example: render initial state
(generate-html initial-state)