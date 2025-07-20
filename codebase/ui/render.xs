; Rendering engine for XS UI
; Converts VNode trees to HTML strings

; Import types
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; HTML escape special characters
(let escape-html (fn (str)
  ; For now, just return the string as-is
  ; In a real implementation, would escape <, >, &, ", '
  str))

; Render attribute to string
(let render-attr (fn (attr)
  (match attr
    ((AttrValue name value)
      (String.concat (String.concat name "=\"") 
                    (String.concat (escape-html value) "\"")))
    ((EventHandler name _)
      ; Event handlers are not rendered in static HTML
      ; They would be attached via JavaScript
      ""))))

; Render attribute list
(rec render-attrs (attrs)
  (match attrs
    ((list) "")
    ((list attr rest)
      (let attr-str (render-attr attr) in
        (if (String.eq attr-str "")
            (render-attrs rest)
            (let rest-str (render-attrs rest) in
              (if (String.eq rest-str "")
                  attr-str
                  (String.concat (String.concat attr-str " ") rest-str))))))))

; Self-closing tags
(let is-self-closing (fn (tag)
  (match tag
    ("img" true)
    ("input" true)
    ("br" true)
    ("hr" true)
    ("meta" true)
    ("link" true)
    (_ false))))

; Render VNode to HTML string
(rec render (vnode)
  (match vnode
    ((Text content) (escape-html content))
    
    ((Element tag attrs children)
      (let attrs-str (render-attrs attrs) in
        (let open-tag (if (String.eq attrs-str "")
                         (String.concat (String.concat "<" tag) ">")
                         (String.concat (String.concat (String.concat "<" tag) " ")
                                      (String.concat attrs-str ">"))) in
          (if (is-self-closing tag)
              ; Self-closing tag
              (String.concat (String.concat "<" tag) 
                           (if (String.eq attrs-str "")
                               " />"
                               (String.concat (String.concat " " attrs-str) " />")))
              ; Normal tag with children
              (let children-str (render-children children) in
                (String.concat open-tag
                             (String.concat children-str
                                          (String.concat "</" 
                                                       (String.concat tag ">")))))))))
    
    ((Fragment children) (render-children children))))

; Render list of children
(rec render-children (children)
  (match children
    ((list) "")
    ((list child rest)
      (String.concat (render child) (render-children rest)))))

; Pretty printing with indentation
(type RenderOptions
  (RenderOptions Bool Int))  ; pretty-print, indent-size

; Render with indentation (helper for pretty printing)
(rec render-pretty (vnode indent)
  (let spaces (make-indent indent) in
    (match vnode
      ((Text content) 
        (String.concat spaces (escape-html content)))
      
      ((Element tag attrs children)
        (let attrs-str (render-attrs attrs) in
          (let open-tag (if (String.eq attrs-str "")
                           (String.concat (String.concat "<" tag) ">")
                           (String.concat (String.concat (String.concat "<" tag) " ")
                                        (String.concat attrs-str ">"))) in
            (if (is-self-closing tag)
                (String.concat spaces
                             (String.concat (String.concat "<" tag)
                                          (if (String.eq attrs-str "")
                                              " />"
                                              (String.concat (String.concat " " attrs-str) " />"))))
                (if (is-inline-element tag children)
                    ; Inline elements on one line
                    (String.concat spaces
                                 (String.concat open-tag
                                              (String.concat (render-children children)
                                                           (String.concat "</"
                                                                        (String.concat tag ">")))))
                    ; Block elements with newlines
                    (String.concat spaces
                                 (String.concat open-tag
                                              (String.concat "\n"
                                                           (String.concat (render-children-pretty children (Int.add indent 2))
                                                                        (String.concat "\n"
                                                                                     (String.concat spaces
                                                                                                  (String.concat "</"
                                                                                                               (String.concat tag ">"))))))))))))
      
      ((Fragment children) 
        (render-children-pretty children indent)))))

; Check if element should be rendered inline
(let is-inline-element (fn (tag children)
  (match children
    ((list (Text _)) true)  ; Single text child
    ((list) true)           ; No children
    (_ false))))            ; Multiple children

; Render children with indentation
(rec render-children-pretty (children indent)
  (match children
    ((list) "")
    ((list child) (render-pretty child indent))
    ((list child rest)
      (String.concat (render-pretty child indent)
                   (String.concat "\n" (render-children-pretty rest indent))))))

; Create indentation string
(rec make-indent (n)
  (if (Int.eq n 0)
      ""
      (String.concat "  " (make-indent (Int.sub n 1)))))

; Helper functions
(let String.eq (fn (s1 s2) false))  ; Placeholder
(let Int.eq (fn (a b) (match (Int.sub a b) (0 true) (_ false))))

; Main render function with options
(let render-to-string (fn (vnode options)
  (match options
    ((RenderOptions pretty indent)
      (if pretty
          (render-pretty vnode 0)
          (render vnode))))))

; Example usage
(let example-vnode
  (Element "div" (list (AttrValue "class" "container")
                      (AttrValue "id" "main"))
           (list (Element "h1" (list) (list (Text "Hello, XS!")))
                 (Element "p" (list (AttrValue "class" "intro"))
                         (list (Text "Welcome to the XS UI library")))
                 (Element "button" (list (AttrValue "type" "button"))
                         (list (Text "Click me"))))))

; Render to HTML
(let html (render example-vnode))
(let pretty-html (render-to-string example-vnode (RenderOptions true 2)))

; Server-side rendering helper
(let render-page (fn (title body-vnode)
  (Element "html" (list)
           (list (Element "head" (list)
                         (list (Element "title" (list) (list (Text title)))))
                 (Element "body" (list)
                         (list body-vnode))))))