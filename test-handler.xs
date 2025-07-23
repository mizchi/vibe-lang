let stateHandler = handler {
  get x k -> fn s -> k s s
  put s k -> fn st -> k () s
}

let example = with stateHandler {
  do {
    let x = perform get
    perform put (x + 1)
    perform get
  }
}

example 0