-- XS Standard Library - List Operations
-- リスト操作のための関数群

-- List construction helpers
let singleton x = [x]
let pair x y = [x, y]

-- List predicates
rec null xs = case xs of {
  [] -> true;
  _ -> false
}

-- List operations
rec length xs = case xs of {
  [] -> 0;
  [h, ...t] -> 1 + length t
}

rec append xs ys = case xs of {
  [] -> ys;
  [h, ...t] -> cons h (append t ys)
}

rec reverse xs = {
  rec revHelper xs acc = case xs of {
    [] -> acc;
    [h, ...t] -> revHelper t (cons h acc)
  };
  revHelper xs []
}

-- Higher-order list operations
rec map f xs = case xs of {
  [] -> [];
  [h, ...t] -> cons (f h) (map f t)
}

rec filter p xs = case xs of {
  [] -> [];
  [h, ...t] -> if p h { cons h (filter p t) } else { filter p t }
}

rec foldLeft f acc xs = case xs of {
  [] -> acc;
  [h, ...t] -> foldLeft f (f acc h) t
}

rec foldRight f xs acc = case xs of {
  [] -> acc;
  [h, ...t] -> f h (foldRight f t acc)
}

-- List searching
rec find p xs = case xs of {
  [] -> Nothing;
  [h, ...t] -> if p h { Just h } else { find p t }
}

rec elem x xs = case xs of {
  [] -> false;
  [h, ...t] -> if x = h { true } else { elem x t }
}

-- List manipulation
rec take n xs = 
  if n = 0 { [] }
  else {
    case xs of {
      [] -> [];
      [h, ...t] -> cons h (take (n - 1) t)
    }
  }

rec drop n xs = 
  if n = 0 { xs }
  else {
    case xs of {
      [] -> [];
      [h, ...t] -> drop (n - 1) t
    }
  }

rec zip xs ys = case xs of {
  [] -> [];
  [xh, ...xt] -> case ys of {
    [] -> [];
    [yh, ...yt] -> cons [xh, yh] (zip xt yt)
  }
}

-- List generation
rec range start end = 
  if start > end { [] }
  else { cons start (range (start + 1) end) }

rec replicate n x = 
  if n = 0 { [] }
  else { cons x (replicate (n - 1) x) }

-- List predicates
rec all p xs = case xs of {
  [] -> true;
  [h, ...t] -> if p h { all p t } else { false }
}

rec any p xs = case xs of {
  [] -> false;
  [h, ...t] -> if p h { true } else { any p t }
}