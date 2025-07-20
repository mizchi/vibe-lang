; Virtual DOM diffing algorithm for XS UI
; Efficiently computes the minimal set of changes between two VNode trees

; Import VNode types
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))

(type Attr
  (AttrValue String String)
  (EventHandler String (fn (Int) Int)))

; Patch operations that can be applied to the DOM
(type Patch
  (Replace VNode)
  (UpdateText String String)  ; old text, new text
  (UpdateAttributes (List Attr) (List Attr))  ; old attrs, new attrs
  (AddChild Int VNode)  ; index, node
  (RemoveChild Int)     ; index
  (ReorderChildren (List Int)))  ; new order indices

; Result of diffing two VNodes
(type DiffResult
  (NoPatch)
  (ApplyPatch (List Patch)))

; Helper to check if two attributes are equal
(rec attrs-equal (a1 a2)
  (match (list a1 a2)
    ((list (AttrValue n1 v1) (AttrValue n2 v2))
      (if (String.eq n1 n2) (String.eq v1 v2) false))
    ((list (EventHandler n1 _) (EventHandler n2 _))
      (String.eq n1 n2))  ; For now, assume handlers with same name are equal
    (_ false)))

; Helper to find attribute by name
(rec find-attr (name attrs)
  (match attrs
    ((list) (None))
    ((list (AttrValue n v) rest)
      (if (String.eq n name) (Some (AttrValue n v)) (find-attr name rest)))
    ((list (EventHandler n h) rest)
      (if (String.eq n name) (Some (EventHandler n h)) (find-attr name rest)))))

; Check if two attribute lists are equal
(rec attrs-list-equal (attrs1 attrs2)
  (match (list attrs1 attrs2)
    ((list (list) (list)) true)
    ((list (list) _) false)
    ((list _ (list)) false)
    ((list (list h1 t1) (list h2 t2))
      (if (attrs-equal h1 h2)
          (attrs-list-equal t1 t2)
          false))))

; Diff two VNodes and return patches
(rec diff (old-vnode new-vnode)
  (match (list old-vnode new-vnode)
    ; Both text nodes
    ((list (Text old-text) (Text new-text))
      (if (String.eq old-text new-text)
          NoPatch
          (ApplyPatch (list (UpdateText old-text new-text)))))
    
    ; Both elements with same tag
    ((list (Element tag1 attrs1 children1) (Element tag2 attrs2 children2))
      (if (String.eq tag1 tag2)
          (let attr-patches (if (attrs-list-equal attrs1 attrs2)
                               (list)
                               (list (UpdateAttributes attrs1 attrs2))) in
            (let child-patches (diff-children children1 children2) in
              (match (list attr-patches child-patches)
                ((list (list) (list)) NoPatch)
                (_ (ApplyPatch (append attr-patches child-patches))))))
          (ApplyPatch (list (Replace new-vnode)))))
    
    ; Both fragments
    ((list (Fragment children1) (Fragment children2))
      (let child-patches (diff-children children1 children2) in
        (if (null child-patches)
            NoPatch
            (ApplyPatch child-patches))))
    
    ; Different node types - replace
    (_ (ApplyPatch (list (Replace new-vnode))))))

; Diff children lists (simplified - no key support yet)
(rec diff-children (old-children new-children)
  (diff-children-indexed old-children new-children 0))

(rec diff-children-indexed (old-children new-children index)
  (match (list old-children new-children)
    ; Both empty
    ((list (list) (list)) (list))
    
    ; Old has more - remove extras
    ((list (list h rest) (list))
      (cons (RemoveChild index) 
            (diff-children-indexed rest (list) (Int.add index 1))))
    
    ; New has more - add extras
    ((list (list) (list h rest))
      (cons (AddChild index h)
            (diff-children-indexed (list) rest (Int.add index 1))))
    
    ; Both have elements - diff them
    ((list (list old-h old-rest) (list new-h new-rest))
      (let patches (match (diff old-h new-h)
                    (NoPatch (list))
                    ((ApplyPatch p) p)) in
        (append patches 
                (diff-children-indexed old-rest new-rest (Int.add index 1)))))))

; Helper functions
(rec append (lst1 lst2)
  (match lst1
    ((list) lst2)
    ((list h rest) (cons h (append rest lst2)))))

(rec null (lst)
  (match lst
    ((list) true)
    (_ false)))

(let length (fn (lst)
  (rec len (lst acc)
    (match lst
      ((list) acc)
      ((list _ rest) (len rest (Int.add acc 1)))))
  (len lst 0)))

; String comparison helpers (placeholders until String.eq is implemented)
(let String.eq (fn (s1 s2) true))  ; Placeholder

; Option type for find-attr
(type Option a
  (None)
  (Some a))

; Example usage
(let old-tree 
  (Element "div" (list (AttrValue "class" "container"))
           (list (Element "h1" (list) (list (Text "Hello")))
                 (Element "p" (list) (list (Text "World"))))))

(let new-tree
  (Element "div" (list (AttrValue "class" "container"))
           (list (Element "h1" (list) (list (Text "Hello")))
                 (Element "p" (list) (list (Text "XS"))))))

; Compute diff
(diff old-tree new-tree)