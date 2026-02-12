function toMessageString(message) {
  if (typeof message === "string") {
    return message;
  }
  return JSON.stringify(message);
}

function tryParseJson(message) {
  if (typeof message !== "string") {
    return message;
  }
  try {
    return JSON.parse(message);
  } catch (_err) {
    return message;
  }
}

export function bindLspTransport(transport, handler) {
  const listener = async (message) => {
    const response = await handler(tryParseJson(message));
    if (response === undefined || response === null) {
      return;
    }
    await transport.send(toMessageString(response));
  };
  const teardown = transport.onMessage(listener);
  return () => {
    if (typeof teardown === "function") {
      teardown();
    }
  };
}

export function createLspBridge(handler) {
  return {
    async handle(message) {
      const response = await handler(tryParseJson(message));
      if (response === undefined) {
        return null;
      }
      return response;
    },
    bind(transport) {
      return bindLspTransport(transport, handler);
    },
  };
}

export function createWebSocketTransport(ws) {
  return {
    send(message) {
      ws.send(message);
    },
    onMessage(handler) {
      const listener = (event) => {
        void handler(event.data);
      };
      ws.addEventListener("message", listener);
      return () => ws.removeEventListener("message", listener);
    },
  };
}
