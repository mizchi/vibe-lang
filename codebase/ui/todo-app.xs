; Todo application example
; A more complex example to test the UI library capabilities

; Types from vdom.xs
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; VNode constructors
(let div (fn (attrs children) (Element "div" attrs children)))
(let ul (fn (attrs children) (Element "ul" attrs children)))
(let li (fn (attrs children) (Element "li" attrs children)))
(let input (fn (attrs) (Element "input" attrs (list))))
(let h1 (fn (attrs children) (Element "h1" attrs children)))
(let button (fn (attrs children) (Element "button" attrs children)))
(let text (fn (content) (Text content)))
(let attr (fn (name value) (AttrValue name value)))
(let on-click (fn (handler) (EventHandler "click" handler)))

; Todo item type
(type TodoItem
  (Todo Int String Bool))  ; id, text, completed

; Application state
(type AppState
  (AppState (List TodoItem) Int))  ; todos and next-id

; Helper functions
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h rest) (cons (f h) (map f rest)))))

(rec filter (pred lst)
  (match lst
    ((list) (list))
    ((list h rest) 
      (if (pred h)
          (cons h (filter pred rest))
          (filter pred rest)))))

(rec length (lst)
  (match lst
    ((list) 0)
    ((list h rest) (+ 1 (length rest)))))

; Render todo item
(let render-todo (fn (todo)
  (match todo
    ((Todo id text completed)
      (li (list (attr "class" (if completed "completed" "active")))
          (list (text text)
                (button (list (on-click (fn (x) id)))
                        (list (text "Toggle")))))))))

; Helper to count active todos
(rec count-active (todos)
  (match todos
    ((list) 0)
    ((list (Todo id text false) rest) (+ 1 (count-active rest)))
    ((list _ rest) (count-active rest))))

; Helper to count completed todos
(rec count-completed (todos)
  (match todos
    ((list) 0)
    ((list (Todo id text true) rest) (+ 1 (count-completed rest)))
    ((list _ rest) (count-completed rest))))

; Render todo list
(let render-todos (fn (todos)
  (ul (list (attr "class" "todo-list"))
      (map render-todo todos))))

; Main app component
(let todo-app (fn (state)
  (match state
    ((AppState todos next-id)
      (div (list (attr "class" "todo-app"))
           (list (h1 (list) (list (text "Todo List")))
                 (div (list (attr "class" "stats"))
                      (list (text "Active: ")
                            (text (Int.toString (count-active todos)))
                            (text " Completed: ")
                            (text (Int.toString (count-completed todos)))))
                 (input (list (attr "type" "text")
                             (attr "placeholder" "Add a todo")))
                 (button (list (on-click (fn (x) (+ x 1))))
                         (list (text "Add")))
                 (render-todos todos)))))))

; Initial state
(let initial-state
  (AppState 
    (list (Todo 1 "Learn XS language" false)
          (Todo 2 "Build UI library" false)
          (Todo 3 "Create todo app" true))
    4))

; Render the app
(todo-app initial-state)